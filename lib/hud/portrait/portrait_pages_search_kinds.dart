/// 竖屏（compact）HUD 的**分类检索页**：歌曲 / 歌手 / 专辑 / 歌单四类 + 分组条。
///
/// 真源与几何来源：
///   `Qt/src/ResponsiveHudPages.cpp:941-990` `library()` 的 `search` 分支（compact 检索页）
///     - 检索框 `{20, y, 353, 47}` + `field("input")` + 右侧 `mobile:search-submit` 命中；
///     - 四个 tab `indexTab(c, {20 + i*90., y, 83, 44}, label, action, selected)`，
///       label 顺序 `{歌曲, 歌手, 专辑, 歌单}`、动作 order `{0, 3, 1, 2}`
///       （= `music:kind:<kinds 下标>`，kinds 见 NativeHudSearch.cpp:63
///       `{"song","album","playlist","artist"}`），指示条 `{20 + selected*90, y+39, 76, 2}`；
///     - `terminalSection(c, y, "01", "检索结果", "INDEX / N")`；
///     - 结果行 `c.row(y + row*68., title, artist, MusicData::time(value), action, pad(row+1))`；
///     - 空态 `fill({20, y+8, 353, .6})` + `icon("search", 20, y+30, 24)` +
///       `text(emptyQuery ? "检索音乐档案" : "暂无匹配档案", 60, y+30, 16, 310)` +
///       `paragraph(emptyQuery ? "输入歌曲、歌手、专辑或歌单名称" : status, 60, y+60, 11, 308)`。
///   `Qt/src/ResponsiveHudCanvas.cpp` 的 `indexTab` / `terminalSection` / `row` 三个原语
///   逐字抄在本文件里（`lib/hud/portrait/portrait_canvas.dart` 只有 `row`，没有前两个）。
///
/// 与 Qt compact 的两处**明示差异**（都不改动作串，只补 compact 缺的入口）：
///   1. 分组条：Qt compact 检索页没有分组 tab（横向 `NativeHudSearch.cpp:85-113` 才有）。
///      本页在「歌曲」分类下补一条三格分组条，标签/键/动作串与横向完全同源
///      （`lib/hud/modals/search_modal.dart` 的 `kSearchGroupLabels / kSearchGroupKeys /
///      searchGroupAction`：`music:group:0..2` = 原序 / 歌手分组 / 专辑分组），
///      另有展开态下的 `music:group-back`「← 全部分组」。
///   2. 载入态：Qt compact 没有 loading 文案；检索是异步的，没有它整页会闪空，
///      因此只在列表顶部补一条「检索中…」，不占结果行位置。
///
/// 与 `portrait_canvas.dart` 一样，这里只把「一次排版」发射成命令流 + 命中表：
/// 滚动、tab 切换、检索输入、播放动作全部归宿主（BasicHudSurface / basic_app）。
/// 所有横向坐标都按 `c.gridWidth` 走，不写死 393（DPI 适配后页宽比 393 宽）。
///
/// 纯 Dart：不 import Flutter，也不新建类（行数据用记录类型传递）。
library;

import 'dart:math' as math;
import 'dart:ui' show Rect;

import 'portrait_canvas.dart';

/// 竖屏 tab 的标签顺序（Qt `ResponsiveHudPages.cpp:948-950` 的 `labels`）。
///
/// 与横向 `NativeHudSearch.cpp:64-65` 的**顺序不同**：横向是 歌曲/专辑/歌单/歌手，
/// 竖屏为了把「歌手」放在第二位改成了 歌曲/歌手/专辑/歌单。
const List<String> portraitSearchKindLabels = <String>['歌曲', '歌手', '专辑', '歌单'];

/// 竖屏 tab 下标 → `music:kind:` 的 kinds 下标（Qt `order = {0, 3, 1, 2}`）。
///
/// kinds 顺序来自 `NativeHudSearch.cpp:63`：`0=song / 1=album / 2=playlist / 3=artist`。
const List<int> portraitSearchKindActionOrder = <int>[0, 3, 1, 2];

/// 竖屏 tab 下标 → 检索分类字符串（Qt `ResponsiveHudPages.cpp:954`
/// `QStringList{"song", "artist", "album", "playlist"}`）。
const List<String> portraitSearchKindKeys = <String>['song', 'artist', 'album', 'playlist'];

/// 分组条标签（与横向 `lib/hud/modals/search_modal.dart` 的 `kSearchGroupLabels` 同源：
/// `Qt/src/NativeHudSearch.cpp:88`）。
const List<String> portraitSearchGroupLabels = <String>['原序', '歌手分组', '专辑分组'];

/// 分组键（与横向 `kSearchGroupKeys` 同源：`Qt/src/NativeHudSearch.cpp:89`）。
const List<String> portraitSearchGroupKeys = <String>['none', 'artist', 'album'];

/// 当前分类在竖屏 tab 里的下标；未知分类回落到 0（Qt 只对 selectedType 取 0 兜底）。
int portraitSearchKindIndex(String searchKind) {
  final int index = portraitSearchKindKeys.indexOf(searchKind);
  return index < 0 ? 0 : index;
}

/// tab 下标对应的动作串 `music:kind:<kinds 下标>`（Qt `ResponsiveHudPages.cpp:956`）。
String portraitSearchKindAction(int index) =>
    'music:kind:${portraitSearchKindActionOrder[index]}';

/// 分组键对应的动作串 `music:group:<下标>`（Qt `NativeHudSearch.cpp:105`）。
String portraitSearchGroupAction(int index) => 'music:group:$index';

/// 分组条动作串的前缀（宿主按 `<前缀><下标>` 解析）。
const String portraitSearchGroupActionPrefix = 'music:group:';

/// 展开某个分组的动作前缀（Qt `music:expand:`，值是按 URL 百分号编码的分组标题）。
const String portraitSearchExpandActionPrefix = 'music:expand:';

/// 分组展开态的返回动作（Qt `NativeHudSearch.cpp:126`）。
const String portraitSearchGroupBackAction = 'music:group-back';

/// 分组展开态的返回文案（Qt `NativeHudSearch.cpp:127` 的 `"← 全部分组"`）。
const String portraitSearchGroupBackText = '← 全部分组';

/// 372 网格里 tab 宽度相对格宽的缩进（Qt `{20 + i*90., y, 83, 44}`：90 格宽 → 83）。
const double _tabWidthInset = 7;

/// `indexTab` 的指示条相对 tab 宽的缩进（Qt `rect.width() - 7` = 83 - 7 = 76）。
const double _tabIndicatorInset = 7;

/// 检索结果行行高（`ResponsiveHudCanvas::row` 的 68）。
const double _rowHeight = 68;

/// 393 网格的左右页边距（Qt 全站 20 / 373）。
const double _left = 20;
double _contentWidth(PortraitCanvas c) => c.gridWidth - 40;

/// 一条结果行。动作串由调用方给（Qt 的 `music:result:0:<index>` 或其它路由），
/// 本绘制器不改写它——命中语义归宿主。
typedef PortraitSearchKindsRow = ({String title, String artist, String stamp, String action});

/// 分类检索页。返回前必须调用 `c.finish()`。
void paintPortraitSearchKindsPage(
  PortraitCanvas c, {
  /// 检索词原文（只用于空态判定：`query.trim().isEmpty` → 「检索音乐档案」）。
  required String query,

  /// 当前分类：`song / album / playlist / artist`（Qt 的 `searchKind`）。
  required String searchKind,

  /// 当前分组键：`none / artist / album`（Qt 的 `groupBy`），默认原序。
  String groupBy = 'none',

  /// 已展开分组的标题；非空时画「← 全部分组」并发出 `music:group-back`。
  String activeGroup = '',

  /// 结果行（一屏即可，超出部分由 `visibleRows` 裁剪 + 宿主滚动）。
  required List<PortraitSearchKindsRow> rows,

  /// 命中总数（`INDEX / <total>`）。
  required int total,

  /// Qt 状态串（空结果时的标题与说明正文都取自它）。
  required String status,

  /// 载入中：只在列表顶部补一条「检索中…」。
  bool loading = false,
}) {
  final double h = c.height;

  // 检索是终端页：整页铺纸色（Qt `paperPage` → `fill({0,0,393,height}, paper)`）。
  c.fill(Rect.fromLTWH(0, 0, c.gridWidth, h), c.paper);
  c.header('音乐检索', back: true, backAction: 'close-modal');

  final double top = math.min(126.0, h * .22);
  final double bottom = _pageBottom(c, top);
  double y = top;

  // --- 检索框（Qt compact `{20, y, 353, 47}`） ---
  //
  // 只画框不画文字：键入的正文与空态占位由 Qt 的输入层自绘
  // （Qt/qml/Overlay.qml:532-612），命令流再画一遍就是双重显示。
  final Rect box = Rect.fromLTWH(_left, y, _contentWidth(c), 47);
  c.fill(box, c.surface);
  c.border(box, c.line);
  c.icon('search', 32, y + 15, size: 17, color: c.muted);
  c.field('search', Rect.fromLTWH(58, y, c.gridWidth - 78, 47));
  c.icon('right', c.gridWidth - 48, y + 15, size: 17);
  c.hit(Rect.fromLTWH(c.gridWidth - 64, y, 44, 47), 'mobile:search-submit', '检索');
  y += 54;

  // --- 四个分类 tab（Qt `indexTab`：宽 83 / 格宽 90 / 高 44，指示条 y+39 高 2） ---
  //
  // 格宽按页宽摊开（设计稿 90 = (393-40)/4 + 约 1.75 的间隙折算）；
  // 直接写死 90 会让宽页（真机 586）四格挤在左边 360 里。
  final int selectedIndex = portraitSearchKindIndex(searchKind);
  final double cell = _contentWidth(c) / portraitSearchKindLabels.length;
  for (int i = 0; i < portraitSearchKindLabels.length; i++) {
    final String label = portraitSearchKindLabels[i];
    final bool selected = i == selectedIndex;
    final Rect tab = Rect.fromLTWH(_left + cell * i, y, cell - _tabWidthInset, 44);
    _indexTab(c, tab, label, portraitSearchKindAction(i), selected);
  }
  // 指示条锚在选中格的左缘（Qt `{20 + selectedType*90, y+39, 76, 2}`）。
  c.fill(Rect.fromLTWH(_left + cell * selectedIndex, y + 39, cell - 2 * _tabIndicatorInset, 2), c.amber);
  y += 53;

  // --- 分组条：只有「歌曲」分类才有（横向 `NativeHudSearch.cpp:85-103` 的同款入口） ---
  if (searchKind == 'song') {
    final double groupCell = _contentWidth(c) / portraitSearchGroupLabels.length;
    for (int i = 0; i < portraitSearchGroupLabels.length; i++) {
      final Rect chip = Rect.fromLTWH(
        _left + groupCell * i,
        y,
        groupCell - _tabWidthInset,
        36,
      );
      c.chip(chip, portraitSearchGroupLabels[i], portraitSearchGroupAction(i),
          selected: groupBy == portraitSearchGroupKeys[i]);
    }
    y += 44;
    if (activeGroup.isNotEmpty) {
      final double backWidth = c.measure(portraitSearchGroupBackText, 10, 'regular') + 12;
      c.text('分组：$activeGroup', _left, y, size: 10, width: _contentWidth(c) - backWidth - 8, color: c.muted);
      c.rightText(portraitSearchGroupBackText, c.gridWidth - 20, y, 10, 'regular');
      c.hit(
        Rect.fromLTWH(c.gridWidth - 20 - backWidth, y - 4, backWidth, 24),
        portraitSearchGroupBackAction,
        '全部分组',
      );
      y += 20;
    }
  }

  // --- 「01 / 检索结果 / INDEX / N」小节头（Qt `terminalSection`） ---
  _terminalSection(c, y, '01', '检索结果', 'INDEX / ${_pad(total)}');
  y += 29;

  final double listTop = math.min(y, bottom);
  final double clipBottom = math.max(listTop, bottom);
  final double restoreBottom = c.contentBottom;
  c.contentBottom = clipBottom;
  c.beginContent(listTop);

  // 载入态只在顶部补一条状态（Qt compact 没有，见文件头的差异说明）。
  double cursor = listTop;
  if (loading) {
    c.text('检索中…', _left, cursor + 8, size: 11, width: _contentWidth(c), color: c.muted);
    cursor += 22;
  }

  if (rows.isEmpty) {
    _emptyState(c, cursor, emptyQuery: query.trim().isEmpty, status: status);
  } else {
    final (int first, int last) = c.visibleRows(cursor, _rowHeight, rows.length);
    for (int i = first; i < last; i++) {
      final PortraitSearchKindsRow row = rows[i];
      c.row(
        cursor + i * _rowHeight,
        title: row.title,
        artist: row.artist,
        stamp: row.stamp,
        action: row.action,
        number: _pad(i + 1),
      );
    }
  }

  c.endContent();
  c.contentBottom = restoreBottom;

  c.finish();
}

/// Qt `indexTab`（ResponsiveHudCanvas.cpp:17-23）逐字移植：
/// 文字 x = rect.x + 7、y = rect.y + 12、宽 = rect.width - 14；
/// 底线 `{rect.x, rect.bottom - 5, rect.width - 7, .6}`；命中整格。
void _indexTab(PortraitCanvas c, Rect rect, String label, String action, bool selected) {
  c.text(
    label,
    rect.left + 7,
    rect.top + 12,
    size: 11,
    width: rect.width - 14,
    weight: selected ? 'demibold' : 'regular',
    color: selected ? c.ink : c.muted,
  );
  c.fill(Rect.fromLTWH(rect.left, rect.bottom - 5, rect.width - _tabWidthInset, .6), c.line);
  c.hit(rect, action, label);
}

/// Qt `terminalSection`（ResponsiveHudPages.cpp:25-31）逐字移植：
/// `fill({20, y, 23, 18}, ink)` + `centered(number, 31.5, y+9, 8)` +
/// `text(title, 51, y+2, 13, 180, "demibold")` + `rightText(caption, 373, y+5, 7, muted)`。
///
/// 373 在宽页上就是 `gridWidth - 20`，所以右锚跟着页宽走。
void _terminalSection(PortraitCanvas c, double y, String number, String title, String caption) {
  c.fill(Rect.fromLTWH(_left, y, 23, 18), c.ink);
  c.centered(number, _left + 11.5, y + 9, 8, 'regular', c.paper);
  c.text(title, _left + 31, y + 2, size: 13, width: 180, weight: 'demibold');
  c.rightText(caption, c.gridWidth - 20, y + 5, 7, 'regular', c.muted);
}

/// Qt compact 空态（ResponsiveHudPages.cpp:978-988）：
/// 细分隔线 + 放大镜 + 标题 + 说明段落。
void _emptyState(PortraitCanvas c, double y, {required bool emptyQuery, required String status}) {
  c.fill(Rect.fromLTWH(_left, y + 8, _contentWidth(c), .6), c.line);
  c.icon('search', _left, y + 30, size: 24, color: c.muted);
  c.text(
    emptyQuery ? '检索音乐档案' : '暂无匹配档案',
    _left + 40,
    y + 30,
    size: 16,
    width: c.gridWidth - 60 - 23,
    weight: 'demibold',
  );
  // Qt 的 `paragraph` 返回排版游标；这里不需要后续排版，只借它折行。
  c.paragraph(
    emptyQuery ? '输入歌曲、歌手、专辑或歌单名称' : status,
    _left + 40,
    y + 60,
    size: 11,
    width: c.gridWidth - 80,
    color: c.muted,
  );
}

/// 页面可用底边：宿主的 `contentBottom`（迷你播放条上沿）与真实画布高度取小，
/// 留 6 网格单位安全边；极小视口下保证至少 60 单位的内容高度（不出 NaN / 负高）。
double _pageBottom(PortraitCanvas c, double top) {
  final double limit = math.max(0.0, math.min(c.contentBottom, c.height) - 6);
  return math.max(top + 60, limit);
}

/// Qt `MusicData::pad`：两位左补零（Qt 的 title 序号列 01..）。
String _pad(int value) => value.toString().padLeft(2, '0');
