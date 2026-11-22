/// 横屏检索弹层（`modal == 'search'`）的面板内容：检索条 + 分类 tab + 分组 tab +
/// 结果行 + 页脚状态。
///
/// 真值口径（Qt）：
///   - 面板边界 / 遮罩 / 标题带归 [ModalShell]（`Qt/src/NativeHudModal.cpp:163-202`
///     的通用路径；search 的宽度与贴右内缩是 :155-157，这里用
///     [modalShellBounds] 求同一份矩形，不再手算）；
///   - 检索条几何 = `Qt/src/NativeHud.cpp:184-186` 的 input 矩形
///     （`bounds.y + 180`，高 54）。宿主的 TextInputOverlay 就摆在这块矩形上
///     （`basic_app.dart` 的 `_searchInputStageRect`），所以面板只画底色、
///     金色竖条与「QUERY / 检索词」标签，不重复画输入文本；
///   - 分类 tab 的标签 / 动作串取自 `lib/hud/modals/search_modal.dart` 的
///     `searchKindLabels / searchKindAction / searchActiveKind`
///     （`Qt/src/NativeHudSearch.cpp:63-83`：动作是 `music:kind:<kinds 下标>`）；
///   - 分组 tab 的三个键 `none / artist / album` 与动作 `music:group:<下标>`
///     来自 `NativeHudSearch.cpp:85-113`；
///   - 结果行动作串沿用竖屏检索页已经移植好的投影（`basic_hud.dart` 的
///     `_portraitSearchRows`）：曲目 `music:index:<i>` / `music:search-open:<i>`、
///     专辑 `music:search-album:<标题>`、歌手 `music:search-artist:<标题>`、
///     歌单 `music:search-playlist:<id>`。
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
    show HudSurfaceSink, HudTextPort, hudFill, hudHitRegion, hudRule, hudText;

/// 一条检索结果行：标题 / 明细（艺人优先，否则专辑）/ 右列（时长或曲目数）/ 动作串。
typedef SearchPanelRow = ({String title, String detail, String stamp, String action});

/// 一次排版算出的纵向锚点（全部是 1080 高舞台坐标）。
typedef SearchPanelGeometry = ({
  ModalShellBounds bounds,
  double barTop,
  double kindTop,
  double groupTop,
  double headerTop,
  double listTop,
  double listBottom,
});

/// 检索条左上角相对面板顶边的偏移：`NativeHud.cpp:184-186` 的 `bounds.y + 180`。
///
/// 与外壳标题带不冲突：标题带最下一行（副标题 top+147、15 号字）底边约 top+162，
/// 所以 `mv_modal.dart` 的内容起点也是 182 一带——检索条在 180 起画不会压到副标题，
/// 两者是同一套「标题带之下」的约定。
const double kSearchPanelBarTop = 180;

/// 检索条高度：`Overlay.qml:531` 的输入层常量 54。
const double kSearchPanelBarHeight = 54;

/// 检索条之下依次排开的距离：分类 tab / 分组 tab / 表头 / 表头下横线 / 行。
const double kSearchPanelKindTopGap = 20;
const double kSearchPanelKindHeight = 32;
const double kSearchPanelGroupTopGap = 10;
const double kSearchPanelGroupHeight = 26;
const double kSearchPanelTableGap = 16;
const double kSearchPanelHeaderRuleGap = 18;
const double kSearchPanelRowHeight = 72;
const double kSearchPanelFooterHeight = 46;

/// 表头与右列共用的右侧预留宽度。
const double _rightReserve = 180;

/// 面板排版：只依赖舞台宽（面板矩形由 [modalShellBounds] 的 search 分支给出）。
SearchPanelGeometry searchPanelGeometry(double stageWidth) {
  final ModalShellBounds bounds = modalShellBounds(modalId: 'search', stageWidth: stageWidth);
  final double barTop = bounds.top + kSearchPanelBarTop;
  final double kindTop = barTop + kSearchPanelBarHeight + kSearchPanelKindTopGap;
  final double groupTop = kindTop + kSearchPanelKindHeight + kSearchPanelGroupTopGap;
  final double headerTop = groupTop + kSearchPanelGroupHeight + kSearchPanelTableGap;
  final double listTop = headerTop + kSearchPanelHeaderRuleGap + 12;
  final double listBottom = bounds.bottom - kSearchPanelFooterHeight;
  return (
    bounds: bounds,
    barTop: barTop,
    kindTop: kindTop,
    groupTop: groupTop,
    headerTop: headerTop,
    listTop: listTop,
    listBottom: listBottom,
  );
}

/// 结果行的可滚动范围（舞台像素）：0 表示一屏放得下。
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
    this.scroll = 0,
  });

  /// 舞台宽（HudStage.width）。
  final double width;
  final bool dark;

  /// 已提交的检索词（空串 = 还没输入）。
  final String query;

  /// 当前分类（`song` / `album` / `playlist` / `artist`）与分组键（`none` / `artist` / `album`）。
  final String searchKind;
  final String groupBy;

  /// 状态串（`state.searchStatus`）与命中总数（`state.searchTotal`）。
  final String status;
  final int total;

  /// 结果行（已经在宿主侧投影好动作串）。
  final List<SearchPanelRow> rows;

  /// 本地音乐（决定分类 tab 的第四格是「歌手」还是「歌单」）。
  final bool localMusic;

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
        title: query.isEmpty ? '检索' : query,
        subtitle: _subtitle(),
        content: (ModalShellBody body) => _paint(body),
      ),
    ).build();
  }

  String _subtitle() {
    final String head = query.isEmpty ? '输入检索词' : 'KEYWORD / 检索词';
    final String tail = total > 0 ? 'INDEX $total 条' : (status.isEmpty ? '未提交检索' : status);
    return '$head · $tail';
  }

  void _paint(ModalShellBody body) {
    final SearchPanelGeometry geometry = searchPanelGeometry(width);
    final ModalShellBounds bounds = geometry.bounds;
    final double left = bounds.left + kModalShellHeaderInset;
    final double usable = bounds.width - kModalShellHeaderInset * 2;
    final bool dark = body.dark;
    final HudSurfaceSink sink = body.sink;

    // 1) 检索条：宿主输入层盖在上面，所以只画底色 + 金色竖条 + 标签。
    hudFill(sink, _barFill(dark), left, geometry.barTop, usable, kSearchPanelBarHeight);
    hudFill(sink, _accent, left, geometry.barTop, 3, kSearchPanelBarHeight);
    hudText(sink, 'QUERY / 检索词', left + 18, geometry.barTop + 8, 9,
        tracking: 0.08, color: _muted(dark), dark: dark);

    // 2) 分类 tab（四格，动作串 music:kind:<kinds 下标>）。
    final List<String> kindLabels = searchKindLabels(localMusic: localMusic);
    final int activeKind = searchActiveKind(searchKind);
    final double kindTop = geometry.kindTop;
    final double kindWidth = usable / kindLabels.length;
    for (int index = 0; index < kindLabels.length; index++) {
      final bool active = index == activeKind;
      final double tabLeft = left + kindWidth * index;
      hudText(sink, kindLabels[index], tabLeft, kindTop + 8, 13,
          weight: active ? 'demibold' : 'regular',
          color: active ? _accent : _muted(dark),
          dark: dark);
      if (active) {
        hudFill(sink, _accent, tabLeft, kindTop + kSearchPanelKindHeight - 3, kindWidth - 26, 3);
      }
      hudHitRegion(sink, tabLeft - 4, kindTop - 4, kindWidth, kSearchPanelKindHeight + 8,
          searchKindAction(index), '分类：${kindLabels[index]}');
    }

    // 3) 分组 tab（原序 / 歌手分组 / 专辑分组，动作串 music:group:<下标>）。
    final double groupTop = geometry.groupTop;
    double cursor = left;
    for (int index = 0; index < kSearchGroupLabels.length; index++) {
      final bool active = kSearchGroupKeys[index] == groupBy;
      final String label = kSearchGroupLabels[index];
      final double labelWidth = body.text.glyphWidth(label, 11, 'regular') + 24;
      hudFill(sink, active ? _accent : _barFill(dark), cursor, groupTop, labelWidth,
          kSearchPanelGroupHeight);
      hudText(sink, label, cursor + 12, groupTop + 7, 11,
          weight: active ? 'demibold' : 'regular',
          color: active ? _onAccent : _muted(dark),
          dark: dark);
      hudHitRegion(sink, cursor, groupTop, labelWidth, kSearchPanelGroupHeight,
          searchGroupAction(index), '分组：$label');
      cursor += labelWidth + 8;
    }

    // 4) 表头 + 结果行。
    final double headerTop = geometry.headerTop;
    hudText(sink, 'TITLE / 标题', left, headerTop, 11,
        weight: 'demibold', dark: dark, color: _muted(dark));
    hudText(sink, 'META / 明细', left + usable * 0.55, headerTop, 11,
        weight: 'demibold', dark: dark, color: _muted(dark));
    hudText(sink, 'LENGTH / 时长', left + usable - _rightReserve, headerTop, 11,
        weight: 'demibold', dark: dark, color: _muted(dark));
    hudRule(sink, dark, left, headerTop + kSearchPanelHeaderRuleGap, usable, 0.24);

    final double listTop = geometry.listTop;
    final double listBottom = geometry.listBottom;
    if (rows.isEmpty) {
      final String message = query.isEmpty ? '检索音乐档案' : (status.isEmpty ? '暂无匹配档案' : status);
      hudText(sink, message, left, listTop + 18, 15, dark: dark);
      hudText(
          sink,
          query.isEmpty ? '输入歌曲、歌手、专辑或歌单名称' : '换个关键词，或切换上面的分类',
          left,
          listTop + 46,
          12,
          color: _muted(dark),
          dark: dark);
    } else {
      final double maximum = searchPanelMaxScroll(width, rows.length);
      final double offset = scroll < 0 ? 0 : (scroll > maximum ? maximum : scroll);
      final int first = (offset ~/ kSearchPanelRowHeight).clamp(0, rows.length - 1);
      for (int index = first; index < rows.length; index++) {
        final double rowY = listTop + index * kSearchPanelRowHeight - offset;
        if (rowY + kSearchPanelRowHeight > listBottom) {
          break;
        }
        _row(body, left, rowY, usable, rows[index]);
      }
      if (maximum > 0) {
        hudText(sink, '共 ${rows.length} 条 · 上下拖动列表滚动', left, listBottom + 3, 10,
            color: _muted(dark), dark: dark);
      }
    }

    // 5) 页脚：状态串 + 关闭提示（Qt `NativeHudSearch.cpp:232-253` 的 searchFooter）。
    hudRule(sink, dark, left, bounds.bottom - kSearchPanelFooterHeight, usable, 0.18);
    hudText(
        sink,
        status.isEmpty
            ? (query.isEmpty ? 'READY / 等待检索词' : 'INDEX / ${rows.length}')
            : status,
        left,
        bounds.bottom - kSearchPanelFooterHeight + 14,
        11,
        color: _muted(dark),
        dark: dark);
    hudText(sink, 'Esc 关闭 · Enter 检索', left + usable - _rightReserve * 2,
        bounds.bottom - kSearchPanelFooterHeight + 14, 11,
        color: _muted(dark), dark: dark);
  }

  void _row(ModalShellBody body, double left, double y, double usable, SearchPanelRow row) {
    final bool dark = body.dark;
    final HudSurfaceSink sink = body.sink;
    hudRule(sink, dark, left, y + kSearchPanelRowHeight - 1, usable, 0.12);
    hudText(sink, body.text.fit(row.title, 17, usable * 0.5, 'demibold'), left, y + 12, 17,
        weight: 'demibold', dark: dark);
    if (row.detail.isNotEmpty) {
      hudText(sink, body.text.fit(row.detail, 12, usable * 0.42), left, y + 36, 12,
          color: _muted(dark), dark: dark);
    }
    if (row.stamp.isNotEmpty) {
      final double stampWidth = body.text.glyphWidth(row.stamp, 13, 'regular');
      hudText(sink, row.stamp, left + usable - stampWidth, y + 14, 13,
          color: _muted(dark), dark: dark);
    }
    hudHitRegion(sink, left, y, usable, kSearchPanelRowHeight - 2, row.action, row.title);
  }
}

// 配色：与横屏检索工具栏同源（`NativeHudSearch.cpp:20-38`）。
const List<Object?> _accent = <Object?>[0.835, 0.639, 0.282, 1];

/// 金色底上的字用暗色（浅色主题下也是暗底金色块，字必须反相）。
const List<Object?> _onAccent = <Object?>[0.06, 0.07, 0.06, 1];

List<Object?> _muted(bool dark) =>
    dark ? const <Object?>[0.92, 0.92, 0.92, 0.55] : const <Object?>[0.10, 0.11, 0.10, 0.55];

List<Object?> _barFill(bool dark) => dark
    ? const <Object?>[0.169, 0.200, 0.173, 1]
    : const <Object?>[0.898, 0.906, 0.855, 1];
