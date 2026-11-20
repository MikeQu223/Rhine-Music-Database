// Rhine Qt -> Flutter parity, card  / 文件 -search_modal.
//
// This file is the search modal CHROME layer only: modal frame geometry, the
// search toolbar (bar / kind tabs / group tabs / table header / group-back
// entry), the footer status line, the input-layer geometry and the pure
// state/action semantics that belong to the modal frame. The result viewport
// rows, scroll rail and auto-fill scroll state are owned by
// lib/hud/modals/search_results.dart; this file only imports the four
// frozen constants and the single SearchColor type defined there, and never
// constructs its layer.
//
// Qt evidence (only source of truth for every number below):
//   Qt/src/NativeHud.cpp:140-158     modalBounds / search modalWidth formula
//   Qt/src/NativeHud.cpp:184-191     input + search list stage geometry (state())
//   Qt/src/NativeHud.h:96-98         ResultListTop/Bottom/RowHeight (frozen)
//   Qt/src/NativeHudSearch.cpp:8-18   toolbar constants
//   Qt/src/NativeHudSearch.cpp:20-42  accent / mutedInk / faintInk / bars
//   Qt/src/NativeHudSearch.cpp:52-129 searchToolbar draw + hit order
//   Qt/src/NativeHudSearch.cpp:232-253 searchFooter
//   Qt/src/NativeHudSearch.cpp:259-281 resetResultViews / ensureSearchFilled gate
//   Qt/src/NativeHudMusic.cpp:148-185 kind / group / expand / group-back
//   Qt/src/MusicLibrary.cpp:435-455   query.trimmed().toUcs4().size() limits
//   Qt/qml/Overlay.qml:520-566        input layer: visibility, hint, Enter/Escape
//
// No Material widget is used to imitate the Qt layer. The only Flutter import
// is CustomPainter; every glyph advance, every text draw and every hit is done
// through the injectable ports below, so this file never hardcodes font
// metrics, never fakes a glyph advance and never fakes the 1.044 baseline
// factor (the host port owns baseline handling).

import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/rendering.dart' show CustomPainter;
import 'package:rhine_music_database/hud/modals/search_results.dart'
    show
        SearchColor,
        kSearchInset,
        kSearchResultListTop,
        kSearchResultListBottom,
        kSearchResultRowHeight,
        percentDecode;

// (a) Frozen cross-module constants (imported, never redefined)
// kSearchInset           = 53  (Qt NativeHudSearch.cpp:8  SearchInset)
// kSearchResultListTop   = 328 (Qt NativeHud.h:96)
// kSearchResultListBottom = 758 (Qt NativeHud.h:97)
// kSearchResultRowHeight = 72  (Qt NativeHud.h:98)
//
// Only these four constants plus SearchColor are imported; SearchResultsLayer
// is never built here and this file must not be imported by search_results.dart
// (no cycle).

// (b) Toolbar constants, one to one with Qt/src/NativeHudSearch.cpp:8-18
/// Qt SearchInset = 53 (NativeHudSearch.cpp:8).
///
/// Named kSearchToolbarInset because the frozen cross-module constant
/// kSearchInset (same value 53) is already imported from search_results.dart
/// and a second top-level kSearchInset would be a duplicate definition.
const double kSearchToolbarInset = 53;

/// Qt SearchBarTop = 172 (NativeHudSearch.cpp:9).
const double kSearchBarTop = 172;

/// Qt SearchBarHeight = 66 (NativeHudSearch.cpp:10).
const double kSearchBarHeight = 66;

/// Qt SearchTabTop = 252 (NativeHudSearch.cpp:11).
const double kSearchTabTop = 252;

/// Qt SearchTabHeight = 36 (NativeHudSearch.cpp:12).
const double kSearchTabHeight = 36;

/// Qt SearchTableY = 302 (NativeHudSearch.cpp:13).
const double kSearchTableY = 302;

/// Qt SearchFooterY = 786 (NativeHudSearch.cpp:14).
const double kSearchFooterY = 786;

/// Qt SearchKindGap = 26 (NativeHudSearch.cpp:15).
const double kSearchKindGap = 26;

/// Qt SearchSortGap = 20 (NativeHudSearch.cpp:16).
const double kSearchSortGap = 20;

/// Qt SearchTitleX = 107 (NativeHudSearch.cpp:17).
const double kSearchTitleX = 107;

/// Qt SearchActionWidth = 136 (NativeHudSearch.cpp:18).
const double kSearchActionWidth = 136;

// Frame constants used by the modalBounds formula (NativeHud.cpp:153-158).
const double kSearchModalTop = 122;
const double kSearchModalHeight = 836;
const double kSearchModalRightInset = 59;
const double kSearchModalStageMargin = 100;
const double kSearchModalMinWidth = 760;
const double kSearchModalMaxWidth = 1000;
const double kSearchModalWidthFactor = 0.5;
const double kSearchModalWidthBias = 59;

// Input layer constants (NativeHud.cpp:184-186 + Overlay.qml:520-566).
const double kSearchInputHeight = 54;
const double kSearchInputVerticalOffset = 180; // bounds.y + 180 == 302
const double kSearchInputFontSize = 22;
const double kSearchInputLeftPadding = 18;
const double kSearchInputRightPadding = 14;
const bool kSearchInputClip = true;

// Toolbar drawing offsets (NativeHudSearch.cpp:59-127).
const double kSearchBarLabelInset = 18;
const double kSearchBarLabelBaselineOffset = 10;
const double kSearchBarLabelFontSize = 9;
const double kSearchBarLabelLetterSpacing = 0.08;
const double kSearchBarGoldWidth = 3;
const double kSearchTabFontSize = 13;
const double kSearchTabBaselineOffset = 10; // 252 + 10 = 262
const double kSearchTabUnderlineBottomInset = 3; // 252 + 36 - 3 = 285
const double kSearchTabUnderlineHeight = 3;
const double kSearchKindHitInset = 4; // hit(cursor - 4, ...)
const double kSearchKindHitPad = 8; // labelWidth + 8
const double kSearchGroupFontSize = 11;
const double kSearchGroupBaselineOffset = 11; // 252 + 11 = 263
const double kSearchGroupUnderlineBottomInset = 2; // 252 + 36 - 2 = 286
const double kSearchGroupUnderlineHeight = 2;
const double kSearchGroupDividerLeftInset = 16;
const double kSearchGroupDividerTopOffset = 6; // 252 + 6 = 258
const double kSearchGroupDividerBottomInset = 12; // 36 - 12 = 24
const double kSearchGroupDividerAlpha = 0.18;
const double kSearchHeaderFontSize = 9;
const double kSearchHeaderLetterSpacing = 0.07;
const double kSearchHeaderRuleAlpha = 0.18; // rule(left, y+288, usable, 0.18)
const double kSearchTableRuleAlpha = 0.24; // rule(left, y+318, usable, 0.24)
const double kSearchTableRuleOffset = 16; // SearchTableY + 16 = 318
const double kSearchGroupBackLabelPad = 16;
const double kSearchGroupBackRightInset = 150;
const double kSearchGroupBackHitTopOffset = 7; // SearchTableY - 7 = 295
const double kSearchGroupBackHitHeight = 28;
const double kSearchGroupBackTextInset = 8;
const double kSearchFooterGoldSize = 5;
const double kSearchFooterGoldTopOffset = 3; // 786 + 3 = 789
const double kSearchFooterStatusInset = 13; // x + 53 + 13 = x + 66
const double kSearchFooterStatusWidthInset = 320; // width - 320
const double kSearchFooterGoldXInset = 53;
const double kSearchFooterFontSize = 10;
const double kSearchFooterLabelFontSize = 9;
const double kSearchFooterLabelLetterSpacing = 0.04;

/// Qt kind order (NativeHudSearch.cpp:63): {song, album, playlist, artist}.
const List<String> kSearchKinds = <String>['song', 'album', 'playlist', 'artist'];

/// Qt local labels (NativeHudSearch.cpp:64): 歌曲/专辑/文件夹/歌手.
const List<String> kSearchKindLabelsLocal = <String>['歌曲', '专辑', '文件夹', '歌手'];

/// Qt online labels (NativeHudSearch.cpp:65): 歌曲/专辑/歌单/歌手.
const List<String> kSearchKindLabelsOnline = <String>['歌曲', '专辑', '歌单', '歌手'];

/// Qt group labels / keys (NativeHudSearch.cpp:89-90).
const List<String> kSearchGroupLabels = <String>['原序', '歌手分组', '专辑分组'];
const List<String> kSearchGroupKeys = <String>['none', 'artist', 'album'];

/// Qt group-back constants (NativeHudSearch.cpp:123-127).
const String kSearchGroupBackText = '← 全部分组';
const String kSearchGroupBackLabel = '全部分组';
const String kSearchGroupBackAction = 'music:group-back';

/// Qt close-modal action used by Escape (Overlay.qml:520-566).
const String kSearchEscapeAction = 'close-modal';

/// Qt search input hint, placeholder and accessibility string are the same
/// (Overlay.qml:520-566).
const String kSearchInputHintLocal = '检索本地歌曲、歌手、专辑或文件夹';
const String kSearchInputHintOnline = '搜索歌曲、歌手、专辑或歌单';

// (c) Modal frame geometry - Qt/src/NativeHud.cpp:153-158

/// Search modal width, exactly Qt NativeHud.cpp:154-156:
/// min(stageWidth - 100, max(760, min(1000, stageWidth * 0.5 - 59))).
///
/// Responsive (portrait) note: the Qt formula already degrades with the
/// available stage width through the outer stageWidth - 100 clamp, so the
/// narrow/portrait host reuses this same formula. This is a responsive
/// semantic branch only; no Qt portrait pixel value exists and none is
/// invented here.
double searchModalWidth(double stageWidth) {
  final double available = stageWidth - kSearchModalStageMargin;
  final double preferred = math.min(
    kSearchModalMaxWidth,
    stageWidth * kSearchModalWidthFactor - kSearchModalWidthBias,
  );
  return math.min(available, math.max(kSearchModalMinWidth, preferred));
}

/// True when the modal is pinned by the available stage width instead of the
/// 760..1000 preferred band. Responsive branch marker for narrow/portrait
/// windows; it does not change any pixel value.
bool searchModalNarrowBranch(double stageWidth) =>
    stageWidth - kSearchModalStageMargin < kSearchModalMinWidth;

/// Qt left = width - modalWidth - 59 for the search modal
/// (NativeHud.cpp:157).
double searchModalLeft(double stageWidth) =>
    stageWidth - searchModalWidth(stageWidth) - kSearchModalRightInset;

/// Qt QRectF{left, 122, modalWidth, 836} (NativeHud.cpp:158).
Rect searchModalBounds(double stageWidth) => Rect.fromLTWH(
      searchModalLeft(stageWidth),
      kSearchModalTop,
      searchModalWidth(stageWidth),
      kSearchModalHeight,
    );

// (d) Input layer / result viewport geometry - NativeHud.cpp:184-191

/// Overlay.qml:520-566 input rectangle on the stage:
/// x = bounds.x + 53, y = bounds.y + 180 (= 302),
/// width = bounds.width - 106 - libraryToolbarActionWidth(), height = 54.
Rect searchInputRect(
  double stageWidth, {
  double libraryToolbarActionWidth = 0,
}) {
  final Rect bounds = searchModalBounds(stageWidth);
  return Rect.fromLTWH(
    bounds.left + kSearchToolbarInset,
    bounds.top + kSearchInputVerticalOffset,
    bounds.width - 2 * kSearchToolbarInset - libraryToolbarActionWidth,
    kSearchInputHeight,
  );
}

/// Qt state() search list viewport (NativeHud.cpp:188-191):
/// (bounds.x + 53, bounds.y + ResultListTop(328),
///  bounds.width - 106, ResultListBottom - ResultListTop(430)).
Rect searchListRect(double stageWidth) {
  final Rect bounds = searchModalBounds(stageWidth);
  return Rect.fromLTWH(
    bounds.left + kSearchInset,
    bounds.top + kSearchResultListTop,
    bounds.width - 2 * kSearchInset,
    kSearchResultListBottom - kSearchResultListTop,
  );
}

/// Qt usable = width - SearchInset * 2 (NativeHudSearch.cpp:54,133).
double searchUsableWidth(double stageWidth) =>
    searchModalWidth(stageWidth) - 2 * kSearchToolbarInset;

// (e) Kind tabs - NativeHudSearch.cpp:63-83

/// Qt label list for the four kind tabs (NativeHudSearch.cpp:64-65).
List<String> searchKindLabels({required bool localMusic}) =>
    localMusic ? kSearchKindLabelsLocal : kSearchKindLabelsOnline;

/// Qt active tab resolution (NativeHudSearch.cpp:66-69):
/// kinds.indexOf(searchKind); if < 0 and searchKind == "folder" then 2.
int searchActiveKind(String searchKind) {
  final int index = kSearchKinds.indexOf(searchKind);
  if (index < 0 && searchKind == 'folder') {
    return 2;
  }
  return index;
}

/// Qt hit action for a kind tab: "music:kind:" + index (NativeHudSearch.cpp:76).
String searchKindAction(int index) => 'music:kind:$index';

/// Qt hit action for a group tab: "music:group:" + index
/// (NativeHudSearch.cpp:105).
String searchGroupAction(int index) => 'music:group:$index';

// (e2) 分类 / 分组动作语义 - Qt/src/NativeHudMusic.cpp:218-252
//
// 工具栏（本文件 e 段）只负责把四个分类 tab 与三个分组 tab 画出来并发出动作串；
// 动作串被点中之后「该改哪些状态、要不要立刻重搜」由 Qt 的 NativeHudMusic
// 分支定义，下面这组纯函数把那四个分支逐字移植成可测试的 reducers：
//
//   kind:       ++m_searchGeneration; listOffset=0; resetResultViews();
//               activeGroup.clear();
//               kind = QStringList{"song","album","playlist","artist"}.value(last,"song");
//               text = query.isEmpty() ? music.keyword : query;
//               if (text.isEmpty()) music.searchKind = kind;   // 只换选中态，不发检索
//               else                music.search(text, kind);   // 立刻重搜
//   group:      music.setGroupView({},{},…); ++generation;
//               groupBy = QStringList{"none","artist","album"}.value(last,"none");
//               activeGroup.clear(); listOffset=0; resetResultViews();
//   expand:     ++generation; key = decode(value.mid(13)); activeGroup = key;
//               listOffset=0; resetResultViews(); 随后按 key 找分组行并 setGroupView
//   group-back: setGroupView({},{},…); ++generation; activeGroup.clear();
//               listOffset=0; resetResultViews();
//
// 分组行（`music:expand:<key>`）的标题与下标由宿主从当前结果行里解析
// （Qt 用 `std::find_if(value["key"] == key)` 找那一行，再 setGroupView(title,
// indices, lane)）：那一步依赖结果列表，不属于「选中态」这一层。

/// Qt `music:kind:<n>` / `music:group:<n>` / `music:expand:<key>` /
/// `music:group-back` 解析后的命令。
sealed class SearchSelectionCommand {
  const SearchSelectionCommand();
}

/// 分类 tab：`music:kind:<kinds 下标>`（NativeHudMusic.cpp:218-229）。
final class SearchKindCommand extends SearchSelectionCommand {
  const SearchKindCommand(this.index);

  /// 发出的下标原文（`music:kind:` 之后的整数）。
  final int index;

  /// Qt `QStringList{"song","album","playlist","artist"}.value(last,"song")`。
  String get kind => searchKindKeyAt(index);
}

/// 分组 tab：`music:group:<groupKeys 下标>`（NativeHudMusic.cpp:230-237）。
final class SearchGroupCommand extends SearchSelectionCommand {
  const SearchGroupCommand(this.index);

  final int index;

  /// Qt `QStringList{"none","artist","album"}.value(last,"none")`。
  String get groupBy => searchGroupKeyAt(index);
}

/// 分组行：`music:expand:<percentEncode(key)>`（NativeHudMusic.cpp:238-249）。
final class SearchExpandCommand extends SearchSelectionCommand {
  const SearchExpandCommand(this.key);

  /// 解百分号编码之后的 group 行 key；解码失败时保留原文
  /// （Qt 的 `QUrl::fromPercentEncoding` 宽容替换，从不失败）。
  final String key;
}

/// 分组内返回：`music:group-back`（NativeHudMusic.cpp:250-256）。
final class SearchGroupBackCommand extends SearchSelectionCommand {
  const SearchGroupBackCommand();
}

/// Qt `kinds.value(index, "song")`：越界一律回落 song（不是抛错）。
String searchKindKeyAt(int index) =>
    index >= 0 && index < kSearchKinds.length ? kSearchKinds[index] : kSearchKinds.first;

/// Qt `groupKeys.value(index, "none")`：越界回落原序。
String searchGroupKeyAt(int index) =>
    index >= 0 && index < kSearchGroupKeys.length
        ? kSearchGroupKeys[index]
        : kSearchGroupKeys.first;

/// 解析分类/分组动作串；不是这四类动作时返回 null（调用方交给别的分支）。
SearchSelectionCommand? searchSelectionCommand(String action) {
  if (action == kSearchGroupBackAction) {
    return const SearchGroupBackCommand();
  }
  const String expand = 'music:expand';
  if (action.startsWith('$expand:')) {
    final String encoded = action.substring(expand.length + 1);
    String key = encoded;
    try {
      key = percentDecode(encoded);
    } on FormatException {
      // Qt 的 fromPercentEncoding 对坏转义宽容：保留原文，不丢点击。
      key = encoded;
    }
    return SearchExpandCommand(key);
  }
  if (action.startsWith('music:kind:')) {
    final int? index = int.tryParse(action.substring('music:kind:'.length));
    return index == null ? null : SearchKindCommand(index);
  }
  if (action.startsWith('music:group:')) {
    final int? index = int.tryParse(action.substring('music:group:'.length));
    return index == null ? null : SearchGroupCommand(index);
  }
  return null;
}

/// HUD 层检索选中态（Qt NativeHudMusic 的 searchKind / groupBy / activeGroup /
/// keyword / query / listOffset，以及 HUD 层的 m_searchGeneration）。
class SearchSelectionState {
  const SearchSelectionState({
    this.searchKind = 'song',
    this.groupBy = 'none',
    this.activeGroup = '',
    this.keyword = '',
    this.query = '',
    this.listOffset = 0,
    this.generation = 0,
  });

  /// 当前分类（Qt `m_music->searchKind`）。
  final String searchKind;

  /// 当前分组键（Qt `groupBy`）。
  final String groupBy;

  /// 已展开分组的 key（Qt `activeGroup`；空 = 未展开，画「← 全部分组」的条件）。
  final String activeGroup;

  /// 已提交的检索词（Qt `music.keyword`）：分类点击在输入框为空时复用它。
  final String keyword;

  /// 输入框实时文本（Qt NativeHud 的 `query`）。
  final String query;

  /// 结果列表滚动偏移（Qt `listOffset`），动作一律归零。
  final int listOffset;

  /// HUD 层检索代次（Qt `m_searchGeneration`），动作一律递增，
  /// 用来作废已排队但未执行的合并检索。
  final int generation;

  SearchSelectionState copyWith({
    String? searchKind,
    String? groupBy,
    String? activeGroup,
    String? keyword,
    String? query,
    int? listOffset,
    int? generation,
  }) =>
      SearchSelectionState(
        searchKind: searchKind ?? this.searchKind,
        groupBy: groupBy ?? this.groupBy,
        activeGroup: activeGroup ?? this.activeGroup,
        keyword: keyword ?? this.keyword,
        query: query ?? this.query,
        listOffset: listOffset ?? this.listOffset,
        generation: generation ?? this.generation,
      );

  @override
  String toString() =>
      'SearchSelectionState(kind: $searchKind, groupBy: $groupBy, '
      'activeGroup: $activeGroup, keyword: $keyword, query: $query, '
      'offset: $listOffset, generation: $generation)';
}

/// 分类点击要立刻发起的检索（Qt `music.search(text, kind)`）。
class SearchKindRun {
  const SearchKindRun({required this.kind, required this.text});

  final String kind;
  final String text;

  @override
  String toString() => 'SearchKindRun(kind: $kind, text: $text)';
}

/// 一个动作应用后的结果：新选中态 + （可选）立刻重搜 + 是否要复位结果视图。
class SearchSelectionChange {
  const SearchSelectionChange({
    required this.state,
    this.run,
    this.resetViews = true,
  });

  final SearchSelectionState state;

  /// 非 null 表示立刻检索（Qt 的 `music.search(text, kind)`）；
  /// null 表示只改选中态（Qt 的 `music.searchKind = kind`）。
  final SearchKindRun? run;

  /// Qt 的 `resetResultViews()`：四个分类/分组分支都会调用，恢复滚动与行缓存。
  final bool resetViews;
}

/// 把一个分类/分组动作应用到选中态（Qt NativeHudMusic.cpp:218-256 四个分支）。
///
/// 顺序与 Qt 相同：先作废排队检索并复位视图/滚动，再改选中态；
/// `music:expand` 的 group 标题与 indices 由宿主在结果行里解析后自行 setGroupView，
/// 本函数只负责 `activeGroup = key`。
SearchSelectionChange searchApplySelection(
  SearchSelectionState state,
  SearchSelectionCommand command,
) {
  switch (command) {
    case SearchKindCommand():
      final String text = state.query.isEmpty ? state.keyword : state.query;
      return SearchSelectionChange(
        state: state.copyWith(
          searchKind: command.kind,
          activeGroup: '',
          listOffset: 0,
          generation: state.generation + 1,
        ),
        // text 为空时 Qt 只写 searchKind，不发检索。
        run: text.isEmpty ? null : SearchKindRun(kind: command.kind, text: text),
      );
    case SearchGroupCommand():
      return SearchSelectionChange(
        state: state.copyWith(
          groupBy: command.groupBy,
          activeGroup: '',
          listOffset: 0,
          generation: state.generation + 1,
        ),
      );
    case SearchExpandCommand():
      return SearchSelectionChange(
        state: state.copyWith(
          activeGroup: command.key,
          listOffset: 0,
          generation: state.generation + 1,
        ),
      );
    case SearchGroupBackCommand():
      return SearchSelectionChange(
        state: state.copyWith(
          activeGroup: '',
          listOffset: 0,
          generation: state.generation + 1,
        ),
      );
  }
}

/// Qt 分组 tab 的出场条件（NativeHudSearch.cpp:85-88）：
/// `std::any_of(lists[0].begin(), lists[0].end(), 行["kind"] == "song")`。
///
/// 工具栏 builder 收的是现成的 `hasSongRows`；这个谓词是它的唯一来源，
/// 免得宿主自己写一份近似判断（比如「分类是 song 就显示」——那在续页把歌曲
/// 换成别的行、或 saved 页混合行时会画错）。
bool searchHasSongRows(List<Map<String, Object?>> rows) {
  for (final Map<String, Object?> row in rows) {
    if (row['kind'] == 'song') {
      return true;
    }
  }
  return false;
}

// Draw-op model: one ordered list, so hit order == draw order, like Qt.

/// Qt accent() (NativeHudSearch.cpp:20-22) and theme ink().
class SearchPalette {
  const SearchPalette({required this.ink, this.dark = true});

  final SearchColor ink;
  final bool dark;

  /// Qt accent {0.835, 0.639, 0.282, 1} (NativeHudSearch.cpp:21).
  static const SearchColor accentColor = SearchColor(0.835, 0.639, 0.282, 1);

  SearchColor get accent => accentColor;

  /// Qt mutedInk(): copy of ink with alpha 0.55 (NativeHudSearch.cpp:24-28).
  SearchColor get mutedInk => ink.withAlpha(0.55);

  /// Qt searchBarFill (NativeHudSearch.cpp:36-38):
  /// dark {0.169, 0.200, 0.173, 1} / light {0.898, 0.906, 0.855, 1}.
  SearchColor get searchBarFill => dark
      ? const SearchColor(0.169, 0.200, 0.173, 1)
      : const SearchColor(0.898, 0.906, 0.855, 1);
}

/// Base class for the ordered draw list.
sealed class SearchDrawOp {
  const SearchDrawOp();
}

/// A filled rectangle (Qt fill).
class SearchFillOp extends SearchDrawOp {
  const SearchFillOp(this.rect, this.color);

  final Rect rect;
  final SearchColor color;
}

/// A hairline / rule drawn with the theme ink at alpha
/// (Qt rule and fill(..., faintInk(ink, alpha))).
class SearchRuleOp extends SearchDrawOp {
  const SearchRuleOp(this.rect, this.alpha);

  final Rect rect;
  final double alpha;
}

/// A text run whose [y] is the Qt text() anchor (NativeHud.cpp:40-43), not the
/// baseline. The renderer derives the baseline as y + size * 1.044; this file
/// never applies that factor.
class SearchTextOp extends SearchDrawOp {
  const SearchTextOp({
    required this.text,
    required this.x,
    required this.y,
    required this.size,
    required this.weight,
    required this.letterSpacing,
    required this.color,
    this.maxWidth,
  });

  final String text;
  final double x;
  final double y;
  final double size;
  final String weight;
  final double letterSpacing;
  final SearchColor color;

  /// Qt fit(text, size, maxWidth, weight) when non-null.
  final double? maxWidth;
}

/// A hit region. Field order is the frozen Qt hit contract:
/// (x, y, width, height, action, label).
class SearchHitOp extends SearchDrawOp {
  const SearchHitOp({
    required this.x,
    required this.y,
    required this.width,
    required this.height,
    required this.action,
    required this.label,
  });

  final double x;
  final double y;
  final double width;
  final double height;
  final String action;
  final String label;

  Rect get rect => Rect.fromLTWH(x, y, width, height);
}

/// Ordered ops for one chrome part (toolbar or footer).
class SearchModalLayout {
  const SearchModalLayout({required this.ops});

  final List<SearchDrawOp> ops;

  Iterable<SearchHitOp> get hits => ops.whereType<SearchHitOp>();
  Iterable<SearchTextOp> get texts => ops.whereType<SearchTextOp>();
  Iterable<SearchFillOp> get fills => ops.whereType<SearchFillOp>();
  Iterable<SearchRuleOp> get rules => ops.whereType<SearchRuleOp>();
}

/// Glyph advance port. Must return the real advance from the host glyph source
/// (native Qt glyph table / Skia measurement); never a fabricated metric.
typedef SearchGlyphWidth = double Function(
  String text,
  double size,
  String weight,
);

// (e/f/g/h) Toolbar layout builder, same order as NativeHudSearch.cpp:52-129

/// Builds the search toolbar ops in Qt draw order:
/// bar fill + gold bar + QUERY label -> four kind tabs (hit, text, underline)
/// -> group tabs divider + (hit, text, underline) -> rule y+288 -> table
/// headers -> rule y+318 -> group-back hit + text.
///
/// [hasSongRows] is NativeHudSearch.cpp:85-87: whether the **raw** lists[0]
/// (before the saved-modal filter) contains any row with kind == "song".
/// Do not pass the filtered rows(lane) result: that predicate is a different
/// one inside rows(lane) (NativeHudController.cpp:203).
SearchModalLayout buildSearchToolbarLayout({
  required double stageWidth,
  required bool localMusic,
  required String searchKind,
  required String groupBy,
  required String activeGroup,
  required bool hasSongRows,
  required SearchPalette palette,
  required SearchGlyphWidth glyphWidth,
}) {
  final Rect bounds = searchModalBounds(stageWidth);
  final double left = bounds.left;
  final double y = bounds.top;
  final double usable = bounds.width - 2 * kSearchToolbarInset;
  final SearchColor muted = palette.mutedInk;
  final SearchColor gold = palette.accent;
  final List<SearchDrawOp> ops = <SearchDrawOp>[];

  // --- search bar (NativeHudSearch.cpp:58-61) ---
  ops.add(SearchFillOp(
    Rect.fromLTWH(left, y + kSearchBarTop, usable, kSearchBarHeight),
    palette.searchBarFill,
  ));
  ops.add(SearchFillOp(
    Rect.fromLTWH(left, y + kSearchBarTop, kSearchBarGoldWidth, kSearchBarHeight),
    gold,
  ));
  ops.add(SearchTextOp(
    text: 'QUERY / 检索词',
    x: left + kSearchBarLabelInset,
    y: y + kSearchBarTop + kSearchBarLabelBaselineOffset,
    size: kSearchBarLabelFontSize,
    weight: 'regular',
    letterSpacing: kSearchBarLabelLetterSpacing,
    color: muted,
  ));

  // --- four kind tabs (NativeHudSearch.cpp:63-83) ---
  final List<String> labels = searchKindLabels(localMusic: localMusic);
  final int activeKind = searchActiveKind(searchKind);
  double cursor = left;
  for (int index = 0; index < labels.length; index++) {
    final String label = labels[index];
    final double labelWidth = glyphWidth(label, kSearchTabFontSize, 'regular');
    final bool active = index == activeKind;
    ops.add(SearchHitOp(
      x: cursor - kSearchKindHitInset,
      y: y + kSearchTabTop,
      width: labelWidth + kSearchKindHitPad,
      height: kSearchTabHeight,
      action: searchKindAction(index),
      label: label,
    ));
    ops.add(SearchTextOp(
      text: label,
      x: cursor,
      y: y + kSearchTabTop + kSearchTabBaselineOffset,
      size: kSearchTabFontSize,
      weight: active ? 'demibold' : 'regular',
      letterSpacing: 0,
      color: active ? palette.ink : muted,
    ));
    if (active) {
      ops.add(SearchFillOp(
        Rect.fromLTWH(
          cursor,
          y + kSearchTabTop + kSearchTabHeight - kSearchTabUnderlineBottomInset,
          labelWidth,
          kSearchTabUnderlineHeight,
        ),
        gold,
      ));
    }
    cursor += labelWidth + kSearchKindGap;
  }

  // --- group tabs: only when a loaded row is kind == song (NativeHudSearch.cpp:85-113) ---
  if (hasSongRows) {
    final List<double> widths = <double>[
      for (final String label in kSearchGroupLabels)
        glyphWidth(label, kSearchGroupFontSize, 'regular'),
    ];
    double total = 0;
    for (final double width in widths) {
      total += width;
    }
    total += kSearchSortGap * (kSearchGroupLabels.length - 1);
    double sortX = left + bounds.width - kSearchToolbarInset - total;
    ops.add(SearchRuleOp(
      Rect.fromLTWH(
        sortX - kSearchGroupDividerLeftInset,
        y + kSearchTabTop + kSearchGroupDividerTopOffset,
        1,
        kSearchTabHeight - kSearchGroupDividerBottomInset,
      ),
      kSearchGroupDividerAlpha,
    ));
    for (int index = 0; index < kSearchGroupLabels.length; index++) {
      final String label = kSearchGroupLabels[index];
      final bool active = groupBy == kSearchGroupKeys[index];
      ops.add(SearchHitOp(
        x: sortX - kSearchKindHitInset,
        y: y + kSearchTabTop,
        width: widths[index] + kSearchKindHitPad,
        height: kSearchTabHeight,
        action: searchGroupAction(index),
        label: label,
      ));
      ops.add(SearchTextOp(
        text: label,
        x: sortX,
        y: y + kSearchTabTop + kSearchGroupBaselineOffset,
        size: kSearchGroupFontSize,
        weight: active ? 'demibold' : 'regular',
        letterSpacing: 0,
        color: active ? palette.ink : muted,
      ));
      if (active) {
        ops.add(SearchFillOp(
          Rect.fromLTWH(
            sortX,
            y + kSearchTabTop + kSearchTabHeight - kSearchGroupUnderlineBottomInset,
            widths[index],
            kSearchGroupUnderlineHeight,
          ),
          gold,
        ));
      }
      sortX += widths[index] + kSearchSortGap;
    }
  }

  // --- rule y+288 + table header + rule y+318 (NativeHudSearch.cpp:115-119) ---
  ops.add(SearchRuleOp(
    Rect.fromLTWH(left, y + kSearchTabTop + kSearchTabHeight, usable, 1),
    kSearchHeaderRuleAlpha,
  ));
  ops.add(SearchTextOp(
    text: 'ID / 编号',
    x: left,
    y: y + kSearchTableY,
    size: kSearchHeaderFontSize,
    weight: 'regular',
    letterSpacing: kSearchHeaderLetterSpacing,
    color: muted,
  ));
  ops.add(SearchTextOp(
    text: 'TITLE / 音乐',
    x: left + kSearchTitleX,
    y: y + kSearchTableY,
    size: kSearchHeaderFontSize,
    weight: 'regular',
    letterSpacing: kSearchHeaderLetterSpacing,
    color: muted,
  ));
  ops.add(SearchTextOp(
    text: 'OPEN',
    x: bounds.left + bounds.width - kSearchActionWidth,
    y: y + kSearchTableY,
    size: kSearchHeaderFontSize,
    weight: 'regular',
    letterSpacing: kSearchHeaderLetterSpacing,
    color: muted,
  ));
  ops.add(SearchRuleOp(
    Rect.fromLTWH(left, y + kSearchTableY + kSearchTableRuleOffset, usable, 1),
    kSearchTableRuleAlpha,
  ));

  // --- group-back entry, only when a group is expanded (NativeHudSearch.cpp:121-128) ---
  if (activeGroup.isNotEmpty) {
    final String label = kSearchGroupBackText;
    final double labelWidth =
        glyphWidth(label, kSearchGroupFontSize, 'regular') + kSearchGroupBackLabelPad;
    final double actionX =
        bounds.left + bounds.width - kSearchToolbarInset - kSearchGroupBackRightInset - labelWidth;
    ops.add(SearchHitOp(
      x: actionX,
      y: y + kSearchTableY - kSearchGroupBackHitTopOffset,
      width: labelWidth,
      height: kSearchGroupBackHitHeight,
      action: kSearchGroupBackAction,
      label: kSearchGroupBackLabel,
    ));
    ops.add(SearchTextOp(
      text: label,
      x: actionX + kSearchGroupBackTextInset,
      y: y + kSearchTableY,
      size: kSearchGroupFontSize,
      weight: 'regular',
      letterSpacing: 0,
      color: palette.ink,
    ));
  }

  return SearchModalLayout(ops: List<SearchDrawOp>.unmodifiable(ops));
}

// (j) Footer - NativeHudSearch.cpp:232-253

/// Qt footer label; null means the whole loaded/total block is not drawn
/// (loaded == 0 && !sourceLoading, NativeHudSearch.cpp:238-241).
///
/// total = max(totals[0], loaded); hint = 正在加载… / SCROLL / 滚动加载 /
/// 全部已载入; label = 已载入 <loaded> / <total> · <hint>.
String? searchFooterLabel({
  required int loaded,
  required int totalItems,
  required bool sourceLoading,
  required bool hasMore,
}) {
  if (loaded == 0 && !sourceLoading) {
    return null;
  }
  final int total = math.max(totalItems, loaded);
  final String hint;
  if (sourceLoading) {
    hint = '正在加载…';
  } else if (hasMore) {
    hint = 'SCROLL / 滚动加载';
  } else {
    hint = '全部已载入';
  }
  return '已载入 $loaded / $total · $hint';
}

/// Footer ops in Qt order: accent 5x5 square, status text, right aligned
/// loaded/total label (NativeHudSearch.cpp:232-253).
SearchModalLayout buildSearchFooterLayout({
  required double stageWidth,
  required String status,
  required int loaded,
  required int totalItems,
  required bool sourceLoading,
  required bool hasMore,
  required SearchPalette palette,
  required SearchGlyphWidth glyphWidth,
}) {
  final Rect bounds = searchModalBounds(stageWidth);
  final double y = bounds.top;
  final SearchColor muted = palette.mutedInk;
  final List<SearchDrawOp> ops = <SearchDrawOp>[];

  ops.add(SearchFillOp(
    Rect.fromLTWH(
      bounds.left + kSearchFooterGoldXInset,
      y + kSearchFooterY + kSearchFooterGoldTopOffset,
      kSearchFooterGoldSize,
      kSearchFooterGoldSize,
    ),
    palette.accent,
  ));
  ops.add(SearchTextOp(
    text: status,
    x: bounds.left + kSearchToolbarInset + kSearchFooterStatusInset,
    y: y + kSearchFooterY,
    size: kSearchFooterFontSize,
    weight: 'regular',
    letterSpacing: 0,
    color: muted,
    maxWidth: bounds.width - kSearchFooterStatusWidthInset,
  ));

  final String? label = searchFooterLabel(
    loaded: loaded,
    totalItems: totalItems,
    sourceLoading: sourceLoading,
    hasMore: hasMore,
  );
  if (label != null) {
    final double labelWidth = glyphWidth(label, kSearchFooterLabelFontSize, 'regular');
    ops.add(SearchTextOp(
      text: label,
      x: bounds.left + bounds.width - kSearchToolbarInset - labelWidth,
      y: y + kSearchFooterY,
      size: kSearchFooterLabelFontSize,
      weight: 'regular',
      letterSpacing: kSearchFooterLabelLetterSpacing,
      color: muted,
    ));
  }

  return SearchModalLayout(ops: List<SearchDrawOp>.unmodifiable(ops));
}

// (k) Query length limits - Qt/src/MusicLibrary.cpp:435-455

/// Qt provider == "qq" ? 60 : 100 (MusicLibrary.cpp:440).
int searchQueryLimit(String provider) => provider == 'qq' ? 60 : 100;

/// Qt query.trimmed().toUcs4().size() (MusicLibrary.cpp:441): trimmed Unicode
/// code point count. Dart String.length is UTF-16 code units and MUST NOT be
/// used (an emoji surrogate pair would count 2).
int searchQueryLength(String query) => query.trim().runes.length;

/// Qt overflow status (MusicLibrary.cpp:455):
/// 请输入 1–<maximum> 字关键词 (en dash U+2013).
String searchQueryOverflowStatus(int maximum) =>
    '请输入 1\u2013$maximum 字关键词';

/// Qt query.isEmpty() || query.toUcs4().size() > maximum after trimming
/// (MusicLibrary.cpp:435-441).
bool searchQueryEmptyOrOverflow(String query, int maximum) =>
    query.trim().isEmpty || searchQueryLength(query) > maximum;

// (l) Input layer semantics - Overlay.qml:520-566 + Engine.cpp:1006-1012

/// Overlay.qml: input is visible when modal == search or modal == saved.
bool searchInputVisibleForModal(String modal) =>
    modal == 'search' || modal == 'saved';

/// Placeholder and accessibility string are the same Qt string.
String searchInputHint({required bool localMusic}) =>
    localMusic ? kSearchInputHintLocal : kSearchInputHintOnline;

/// Result of Qt Engine::searchAccepted(text, modifiers)
/// (Engine.cpp:1006-1012): ControlModifier -> key("Enter", true); otherwise
/// query(text).
class SearchAcceptedCommand {
  const SearchAcceptedCommand.key(this.keyName, {required this.command})
      : query = null;

  const SearchAcceptedCommand.query(this.query)
      : keyName = null,
        command = false;

  final String? keyName;
  final bool command;
  final String? query;

  bool get isKey => keyName != null;

  /// Stable textual form for tests/logging.
  String get actionString =>
      isKey ? 'key($keyName, command: $command)' : 'query($query)';
}

/// Qt Engine::searchAccepted (Engine.cpp:1006-1012).
SearchAcceptedCommand searchAccepted(String text, bool controlModifier) =>
    controlModifier
        ? const SearchAcceptedCommand.key('Enter', command: true)
        : SearchAcceptedCommand.query(text);

// Auto-fill gate only (NativeHudSearch.cpp:268-281). The scroll/row-count state
// itself is owned by search_results.dart; this predicate never mutates it.

/// Qt ensureSearchFilled gate conditions (NativeHudSearch.cpp:269-276).
bool shouldAutoFillSearch({
  required String modal,
  required bool closing,
  required String query,
  required String keyword,
  required bool sourceLoading,
  required bool hasMore,
  required int rowCount,
  required int autoFillSize,
}) {
  if (modal != 'search' || closing) {
    return false;
  }
  if (query.trim() != keyword || sourceLoading || !hasMore) {
    return false;
  }
  return rowCount > autoFillSize;
}

/// Qt count * ResultRowHeight < ResultListBottom - ResultListTop
/// (NativeHudSearch.cpp:278).
bool searchAutoFillNeedsMore(int rowCount) =>
    rowCount * kSearchResultRowHeight <
    kSearchResultListBottom - kSearchResultListTop;

// (m/n) Painter adapter: all text + hits through injectable ports

/// Ports the host must provide. Glyph advance and text drawing must be real
/// (host glyph table / Skia), and hit collection must preserve the six-field
/// Qt order (x, y, width, height, action, label).
abstract class SearchModalPorts {
  /// Real glyph advance for text at size/weight; no fabricated values.
  double glyphWidth(String text, double size, String weight);

  /// Draws a text run. SearchTextOp.y is the Qt text() anchor, not the
  /// baseline: the renderer computes baseline = y + size * 1.044 and applies
  /// any fit() truncation.
  void drawText(SearchTextOp op);

  /// Hit collection, frozen Qt field order.
  void addHit(
    double x,
    double y,
    double width,
    double height,
    String action,
    String label,
  );
}

/// CustomPainter adapter for one chrome part (toolbar or footer). Fill/rule
/// drawing is local; every text draw and hit goes through ports, preserving
/// the exact op order produced by the layout builders.
class SearchModalPainter extends CustomPainter {
  const SearchModalPainter({
    required this.layout,
    required this.ports,
    required this.ink,
  });

  final SearchModalLayout layout;
  final SearchModalPorts ports;

  /// Theme ink, used for rules only (rules are ink at a per-op alpha).
  final SearchColor ink;

  @override
  void paint(Canvas canvas, Size size) {
    final Paint paint = Paint();
    for (final SearchDrawOp op in layout.ops) {
      switch (op) {
        case final SearchFillOp fill:
          canvas.drawRect(fill.rect, paint..color = fill.color.toColor());
        case final SearchRuleOp rule:
          canvas.drawRect(
            rule.rect,
            paint..color = ink.withAlpha(rule.alpha).toColor(),
          );
        case final SearchTextOp text:
          ports.drawText(text);
        case final SearchHitOp hit:
          ports.addHit(hit.x, hit.y, hit.width, hit.height, hit.action, hit.label);
      }
    }
  }

  @override
  bool shouldRepaint(covariant SearchModalPainter oldDelegate) =>
      !identical(oldDelegate.layout, layout) ||
      oldDelegate.ink != ink ||
      !identical(oldDelegate.ports, ports);
}
