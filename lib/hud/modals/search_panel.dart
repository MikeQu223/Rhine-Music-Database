/// 横屏检索弹层（`modal == 'search'`）的面板内容：检索条 + 分类 tab + 分组 tab +
/// 结果行 + 页脚状态。
///
/// 真值口径（Qt，逐条对照 `Qt/src/NativeHudSearch.cpp`）：
///   - 面板边界 / 遮罩 / 标题带归 [ModalShell]（`Qt/src/NativeHudModal.cpp:163-214`
///     的通用路径；search 的宽度与贴右内缩是 `Qt/src/NativeHud.cpp:219-224`，
///     这里用 [modalShellBounds] 求同一份矩形，不再手算）；
///   - 面板内所有 y 常量都是**相对面板顶边**：检索条 172/66（`NativeHudSearch.cpp:10-11`）、
///     分类与分组 tab 252/36（:12-13）、表头 302（:14）、表头下横线 302+16（:116）、
///     结果列表 328..758（`Qt/src/NativeHud.h:121-122` 的 `ResultListTop/ResultListBottom`）、
///     行高 72（:123）、页脚 786（`NativeHudSearch.cpp:15`）；
///   - 左右内缩 `SearchInset = 53`（:9），标题列 `SearchTitleX = 107`（:16），
///     右侧「查看」列 `SearchActionWidth = 136`（:17），
///     分类 tab 间距 26（:14）、分组 tab 间距 20（:15）；
///   - 分类 tab 的标签 / 动作串取自 `lib/hud/modals/search_modal.dart` 的
///     `searchKindLabels / searchKindAction / searchActiveKind`（`NativeHudSearch.cpp:63-83`）；
///   - 分组 tab 的三个键 `none / artist / album` 与动作 `music:group:<下标>`
///     来自 `NativeHudSearch.cpp:85-113`（只有结果里含曲目时才出现）；
///   - 结果行动作串由宿主投影好（`basic_hud.dart` 的 `_searchPanelRows`）：
///     曲目 `music:index:<i>` / `music:search-open:<i>`、专辑 / 歌手 / 歌单走各自的语义动作。
///
/// 本文件只画、不解释状态：滚动位置由调用方传入，点击后的状态迁移全归宿主与 HUD 分派。
library;

import 'dart:math' as math;

import 'package:rhine_music_database/hud/modals/modal_shell.dart';
import 'package:rhine_music_database/hud/modals/search_modal.dart'
    show
        kSearchGroupKeys,
        kSearchGroupLabels,
        searchActiveKind,
        searchGroupAction,
        searchKindAction,
        searchKindLabels;
import 'package:rhine_music_database/hud/pages/chrome.dart'
    show
        HudSurfaceSink,
        HudTextPort,
        hudFill,
        hudHitRegion,
        hudInk,
        hudOp,
        hudRule,
        hudText;

/// 一条检索结果行。
///
/// 字段逐项对应 Qt `NativeHudSearch.cpp:176-214` 的 `resultListRow`：
/// `id`（左列编号，10 号、宽上限 92）、`title`（18 号 demibold，x = 面板左 + 107）、
/// `kind`（标签块里的大写分类，8 号）、`detail`（标签块右侧的明细，10 号）、
/// `action`（整行命中区）。
typedef SearchPanelRow = ({
  String id,
  String title,
  String detail,
  String kind,
  String action,
});

/// 一次排版算出的纵向锚点（全部是 1080 高舞台坐标，已折算面板顶边）。
typedef SearchPanelGeometry = ({
  ModalShellBounds bounds,
  double barTop,
  double tabTop,
  double tableTop,
  double listTop,
  double listBottom,
  double footerTop,
});

// 面板内相对常量：Qt `NativeHudSearch.cpp:9-17` + `Qt/src/NativeHud.h:121-123`。
const double kSearchPanelInset = 53;
const double kSearchPanelBarTop = 172;
const double kSearchPanelBarHeight = 66;
const double kSearchPanelTabTop = 252;
const double kSearchPanelTabHeight = 36;
const double kSearchPanelTableTop = 302;
const double kSearchPanelTableRuleGap = 16;
const double kSearchPanelListTop = 328;
const double kSearchPanelListBottom = 758;
const double kSearchPanelFooterTop = 786;
const double kSearchPanelKindGap = 26;
const double kSearchPanelSortGap = 20;
const double kSearchPanelTitleX = 107;
const double kSearchPanelActionWidth = 136;
const double kSearchPanelRowHeight = 72;

/// 面板排版：只依赖舞台宽（面板矩形由 [modalShellBounds] 的 search 分支给出）。
SearchPanelGeometry searchPanelGeometry(double stageWidth) {
  final ModalShellBounds bounds = modalShellBounds(modalId: 'search', stageWidth: stageWidth);
  return (
    bounds: bounds,
    barTop: bounds.top + kSearchPanelBarTop,
    tabTop: bounds.top + kSearchPanelTabTop,
    tableTop: bounds.top + kSearchPanelTableTop,
    listTop: bounds.top + kSearchPanelListTop,
    listBottom: bounds.top + kSearchPanelListBottom,
    footerTop: bounds.top + kSearchPanelFooterTop,
  );
}

/// 结果行的可滚动范围（舞台像素）：0 表示一屏放得下
/// （Qt `NativeHud::searchScrollMaximum`：`HudScroll::maximum(rows*72, 430)`）。
double searchPanelMaxScroll(double stageWidth, int rowCount) {
  final SearchPanelGeometry geometry = searchPanelGeometry(stageWidth);
  final double content = rowCount * kSearchPanelRowHeight;
  final double viewport = geometry.listBottom - geometry.listTop;
  return content <= viewport ? 0 : content - viewport;
}

/// 横屏检索面板。
class SearchPanel {
  const SearchPanel({
    required this.width,
    required this.dark,
    required this.query,
    required this.searchKind,
    required this.groupBy,
    required this.status,
    required this.total,
    required this.rows,
    this.localMusic = true,
    this.hasSongs = false,
    this.scroll = 0,
  });

  /// 舞台宽（HudStage.width）。
  final double width;
  final bool dark;

  /// 已提交的检索词（只用于标题命中的下划线；输入文本在 Overlay 输入层里）。
  final String query;

  /// 当前分类（`song` / `album` / `playlist` / `artist`）与分组键（`none` / `artist` / `album`）。
  final String searchKind;
  final String groupBy;

  /// 状态串（`state.searchStatus`）与命中总数（`state.searchTotal`）。
  final String status;
  final int total;

  /// 结果行（已经在宿主侧投影好动作串）。
  final List<SearchPanelRow> rows;

  /// 本地音乐（决定分类 tab 的第三格是「文件夹」还是「歌单」、
  /// 以及空态提示文案，`NativeHudSearch.cpp:64-66` / :146-149）。
  final bool localMusic;

  /// 结果里是否含曲目：决定分组 tab 是否出现（`NativeHudSearch.cpp:85-88`）。
  final bool hasSongs;

  /// 行级滚动偏移（舞台像素，0 = 首行贴表头）。
  final double scroll;

  ModalShellResult build(HudSurfaceSink sink, HudTextPort text) {
    return ModalShell(
      sink: sink,
      text: text,
      spec: ModalShellSpec(
        modalId: 'search',
        stageWidth: width,
        dark: dark,
        // Qt `NativeHudModal.cpp:26-30` 的 titles 表没有 search，
        // 落到 `MUSIC INDEX`；副标题是 :66-72 的 `音乐检索`（本地平台另有文案）。
        title: 'MUSIC INDEX',
        subtitle: localMusic ? '本地音乐检索 / 仅搜索已导入的索引' : '音乐检索',
        content: (ModalShellBody body) => _paint(body),
      ),
    ).build();
  }

  void _paint(ModalShellBody body) {
    final SearchPanelGeometry geometry = searchPanelGeometry(width);
    final ModalShellBounds bounds = geometry.bounds;
    final double left = bounds.left + kSearchPanelInset;
    final double usable = bounds.width - kSearchPanelInset * 2;
    final bool dark = body.dark;
    final HudSurfaceSink sink = body.sink;
    final List<Object?> ink = hudInk(dark);
    final List<Object?> muted = _muted(ink);

    // 1) 检索条：宿主输入层（y 172+8、高 54）盖在上面，所以只画底色 + 金色竖条 + 标签。
    hudFill(sink, _barFill(dark), left, geometry.barTop, usable, kSearchPanelBarHeight);
    hudFill(sink, _accent, left, geometry.barTop, 3, kSearchPanelBarHeight);
    hudText(sink, 'QUERY / 检索词', left + 18, geometry.barTop + 10, 9,
        tracking: 0.08, color: muted, dark: dark);

    // 2) 分类 tab（左对齐流式排列；动作串 music:kind:<kinds 下标>）。
    final List<String> kindLabels = searchKindLabels(localMusic: localMusic);
    final int activeKind = searchActiveKind(searchKind);
    final double tabTop = geometry.tabTop;
    double cursor = left;
    for (int index = 0; index < kindLabels.length; index++) {
      final String label = kindLabels[index];
      final bool active = index == activeKind;
      final double labelWidth = body.text.glyphWidth(label, 13);
      hudHitRegion(sink, cursor - 4, tabTop, labelWidth + 8, kSearchPanelTabHeight,
          searchKindAction(index), label);
      hudText(sink, label, cursor, tabTop + 10, 13,
          weight: active ? 'demibold' : 'regular',
          color: active ? ink : muted,
          dark: dark);
      if (active) {
        hudFill(sink, _accent, cursor, tabTop + kSearchPanelTabHeight - 3, labelWidth, 3);
      }
      cursor += labelWidth + kSearchPanelKindGap;
    }

    // 3) 分组 tab：与分类 tab 同一行、右对齐；动作串 music:group:<下标>。
    if (hasSongs) {
      final List<double> widths = <double>[
        for (final String label in kSearchGroupLabels) body.text.glyphWidth(label, 11),
      ];
      final double totalWidth = widths.fold<double>(0, (double a, double b) => a + b) +
          kSearchPanelSortGap * (kSearchGroupLabels.length - 1);
      double sortX = bounds.left + bounds.width - kSearchPanelInset - totalWidth;
      hudFill(sink, _faint(ink, 0.18), sortX - 16, tabTop + 6, 1, kSearchPanelTabHeight - 12);
      for (int index = 0; index < kSearchGroupLabels.length; index++) {
        final String label = kSearchGroupLabels[index];
        final bool active = kSearchGroupKeys[index] == groupBy;
        hudHitRegion(
            sink, sortX - 4, tabTop, widths[index] + 8, kSearchPanelTabHeight,
            searchGroupAction(index), label);
        hudText(sink, label, sortX, tabTop + 11, 11,
            weight: active ? 'demibold' : 'regular',
            color: active ? ink : muted,
            dark: dark);
        if (active) {
          hudFill(
              sink, _accent, sortX, tabTop + kSearchPanelTabHeight - 2, widths[index], 2);
        }
        sortX += widths[index] + kSearchPanelSortGap;
      }
    }

    // 4) 分组内的返回入口（`NativeHudSearch.cpp:120-127`）。
    if (groupBy != 'none' && groupBy.isNotEmpty) {
      const String label = '← 全部分组';
      final double labelWidth = body.text.glyphWidth(label, 11) + 16;
      final double actionX =
          bounds.left + bounds.width - kSearchPanelInset - 150 - labelWidth;
      hudHitRegion(sink, actionX, geometry.tableTop - 7, labelWidth, 28, 'music:group-back', '全部分组');
      hudText(sink, label, actionX + 8, geometry.tableTop, 11, color: ink, dark: dark);
    }

    // 5) tab 下横线 + 表头 + 表头下横线（:115-118）。
    hudRule(sink, dark, left, tabTop + kSearchPanelTabHeight, usable, 0.18);
    hudText(sink, 'ID / 编号', left, geometry.tableTop, 9,
        tracking: 0.07, color: muted, dark: dark);
    hudText(sink, 'TITLE / 音乐', left + kSearchPanelTitleX, geometry.tableTop, 9,
        tracking: 0.07, color: muted, dark: dark);
    hudText(sink, 'OPEN', bounds.left + bounds.width - kSearchPanelActionWidth,
        geometry.tableTop, 9,
        tracking: 0.07, color: muted, dark: dark);
    hudRule(sink, dark, left, geometry.tableTop + kSearchPanelTableRuleGap, usable, 0.24);

    // 6) 结果列表（328..758，独立滚动区，`NativeHudSearch.cpp:131-174`）。
    final double listTop = geometry.listTop;
    final double listBottom = geometry.listBottom;
    final double viewportHeight = listBottom - listTop;
    final double maximum = searchPanelMaxScroll(width, rows.length);
    final double offset = scroll < 0 ? 0 : (scroll > maximum ? maximum : scroll);
    if (rows.isEmpty) {
      // 空态：标题 18 号 demibold 在 +92、提示 12 号在 +128（`NativeHudSearch.cpp:145-150`）。
      final String message = status.isEmpty ? '检索音乐档案' : status;
      hudText(sink, body.text.fit(message, 18, usable, 'demibold'), left, listTop + 92, 18,
          weight: 'demibold', dark: dark);
      hudText(
          sink,
          localMusic ? '在文件夹管理中导入音乐后即可检索。' : '输入歌曲、歌手、专辑或歌单名称后按 ENTER。',
          left,
          listTop + 128,
          12,
          color: muted,
          dark: dark);
    } else {
      // 与 Qt 同口径：起点多取一行、终点多取一行，超出视口的部分由 clip 裁掉。
      final int first = (offset ~/ kSearchPanelRowHeight).floor().clamp(0, rows.length - 1);
      final int last = ((offset + viewportHeight) / kSearchPanelRowHeight)
          .ceil()
          .clamp(0, rows.length - 1);
      hudOp(sink, <Object?>['save']);
      hudOp(sink, <Object?>['clip', left, listTop, usable, viewportHeight]);
      for (int index = first; index <= last; index++) {
        final double rowY = listTop + index * kSearchPanelRowHeight - offset;
        _row(body, bounds, left, usable, rowY, rows[index], listTop, listBottom);
      }
      hudOp(sink, <Object?>['restore']);

      // 右侧滚动轨（:163-174 的 railX = x + width - 24）。
      _rail(sink, ink, bounds.left + bounds.width - 24, listTop, viewportHeight, maximum, offset,
          rows.length * kSearchPanelRowHeight);
    }

    // 7) 页脚（`NativeHudSearch.cpp:227-253`）：金色方块 + 状态串 + 右侧载入量。
    final double footerTop = geometry.footerTop;
    hudFill(sink, _accent, bounds.left + kSearchPanelInset, footerTop + 3, 5, 5);
    hudText(
        sink,
        body.text.fit(status.isEmpty ? 'READY / 等待检索词' : status, 10, bounds.width - 320),
        bounds.left + kSearchPanelInset + 13,
        footerTop,
        10,
        color: muted,
        dark: dark);
    final int loaded = rows.length;
    final int totalCount = total > loaded ? total : loaded;
    final String hint = maximum > 0 ? 'SCROLL / 滚动加载' : '全部已载入';
    final String label = '已载入 $loaded / $totalCount · $hint';
    final double labelWidth = body.text.glyphWidth(label, 9);
    hudText(sink, label, bounds.left + bounds.width - kSearchPanelInset - labelWidth, footerTop, 9,
        tracking: 0.04, color: muted, dark: dark);
  }

  void _row(ModalShellBody body, ModalShellBounds bounds, double left, double usable, double y,
      SearchPanelRow row, double listTop, double listBottom) {
    final bool dark = body.dark;
    final HudSurfaceSink sink = body.sink;
    final HudTextPort text = body.text;
    final List<Object?> ink = hudInk(dark);
    final List<Object?> muted = _muted(ink);
    // Qt `resultListRow` 的宽度口径用的是面板宽（不是 usable），照抄以免标题列变窄。
    final double titleWidth = bounds.width - 308;

    hudRule(sink, dark, left, y + kSearchPanelRowHeight - 1, usable, 0.16);
    hudText(sink, text.fit(row.id, 10, 92), left, y + 20, 10, color: muted, dark: dark);
    _title(body, row, left + kSearchPanelTitleX, y + 11, titleWidth);

    final String kind = row.kind.isEmpty ? 'SONG' : row.kind;
    final double tagWidth = text.glyphWidth(kind, 8) + 10;
    hudFill(sink, _tagFill(dark), left + kSearchPanelTitleX, y + 40, tagWidth, 14);
    hudText(sink, kind, left + kSearchPanelTitleX + 5, y + 41, 8,
        tracking: 0.06, color: muted, dark: dark);
    if (row.detail.isNotEmpty) {
      hudText(sink, text.fit(row.detail, 10, titleWidth - tagWidth - 8), left + kSearchPanelTitleX + tagWidth + 8,
          y + 40, 10,
          color: muted, dark: dark);
    }
    hudText(sink, '查看 ↗', bounds.left + bounds.width - kSearchPanelActionWidth, y + 20, 11,
        color: muted, dark: dark);

    // 命中区裁到视口内（Qt `HudScroll::clipHits`：先把矩形与视口求交，空的丢掉）。
    final double hitTop = math.max(y, listTop);
    final double hitBottom = math.min(y + kSearchPanelRowHeight, listBottom);
    if (hitBottom > hitTop) {
      hudHitRegion(sink, left, hitTop, usable, hitBottom - hitTop, row.action, row.title);
    }
  }

  /// 标题 + 命中词下划线（`NativeHudSearch.cpp:218-241` 的 `searchTitle`）。
  void _title(ModalShellBody body, SearchPanelRow row, double x, double y, double width) {
    final HudSurfaceSink sink = body.sink;
    final HudTextPort text = body.text;
    final String shown = text.fit(row.title, 18, width, 'demibold');
    hudText(sink, shown, x, y, 18, weight: 'demibold', dark: body.dark);
    if (query.isEmpty) {
      return;
    }
    final int index = shown.toLowerCase().indexOf(query.toLowerCase());
    if (index < 0) {
      return;
    }
    final double prefix = text.glyphWidth(shown.substring(0, index), 18, 'demibold');
    final double match = text.glyphWidth(
        shown.substring(index, math.min(shown.length, index + query.length)), 18, 'demibold');
    if (match > 0) {
      hudFill(sink, _accent, x + prefix, y + 19, match, 2);
    }
  }

  /// 滚动轨（Qt `HudScroll::rail`，`NativeHudSearch.cpp:163-174`）。
  void _rail(HudSurfaceSink sink, List<Object?> ink, double railX, double listTop,
      double viewportHeight, double maximum, double offset, double content) {
    if (maximum <= 0) {
      return;
    }
    final double railTop = listTop + 8;
    final double railHeight = viewportHeight - 16;
    hudFill(sink, _faint(ink, 0.10), railX, railTop, 3, railHeight);
    final double thumbHeight =
        math.min(railHeight, math.max(30.0, railHeight * viewportHeight / content));
    final double travel = railHeight - thumbHeight;
    final double thumbTop = railTop + (maximum <= 0 ? 0 : travel * (offset / maximum));
    hudFill(sink, _faint(ink, 0.45), railX, thumbTop, 3, thumbHeight);
  }

}

// 配色：与横屏检索工具栏同源（`NativeHudSearch.cpp:22-42`）。
const List<Object?> _accent = <Object?>[0.835, 0.639, 0.282, 1];

List<Object?> _muted(List<Object?> ink) {
  final List<Object?> value = <Object?>[ink[0], ink[1], ink[2], 0.55];
  return value;
}

List<Object?> _faint(List<Object?> ink, double alpha) {
  final List<Object?> value = <Object?>[ink[0], ink[1], ink[2], alpha];
  return value;
}

List<Object?> _barFill(bool dark) => dark
    ? const <Object?>[0.169, 0.200, 0.173, 1]
    : const <Object?>[0.898, 0.906, 0.855, 1];

/// Qt `searchTagFill`（:40-42）。
List<Object?> _tagFill(bool dark) =>
    dark ? const <Object?>[1, 1, 1, 0.07] : const <Object?>[0.10, 0.11, 0.10, 0.05];
