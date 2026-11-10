// T35-C19-W2 (PAGE-SEARCH) — Qt 检索结果层：纯几何/状态 + 可注入端口的 CustomPainter 适配。
//
// Qt 真源：
//   Qt/src/NativeHudSearch.cpp:131-211 结果列表 / 行内容 / 标题匹配
//   Qt/src/NativeHudSearch.cpp:255-281 滚动最大値 / resetResultViews / ensureSearchFilled
//   Qt/src/NativeHudSearch.cpp:7-43     Search* 常量与配色
//   Qt/src/NativeHudController.cpp:183-260 分组派生 rows(lane)
//   Qt/src/NativeHud.h:96-98           ResultListTop / ResultListBottom / ResultRowHeight
//   Qt/src/HudScroll.h:10-95           maximum / clampOffset / applyWheel / visibleRange / rail / clipHits
//   Qt/src/NativeHud.cpp:40-43,102-110 text()/hit() 的字段顺序
//
// 本文件同时承载：
//   1) 纯几何 / 状态 / 动作层（只用 dart:ui 的 Rect/Offset/Size，无 Material，无别树依赖）
//   2) SearchResultsLayer（CustomPainter）：只把与 Qt HUD op 流等价的指令交给注入端口，
//      字形 advance 与 1.044 baseline 全部由端口实现方负责，本文件不伪造任何字体度量。
//
// 为什么本文件不 import package:flutter/material.dart：
//   T35 卡片明令禁止用 Material 组件搭旧 Flutter 界面，并禁止纯几何/状态层 import material。
//   两个约束落在同一文件里时强制项优先；因此适配层改用 package:flutter/rendering.dart
//   提供的 CustomPainter（不含 Material 设计系统），绘制本身仍走端口。

import 'dart:convert' show utf8;
import 'dart:math' as math;
import 'dart:ui' show Canvas, Color, Offset, Rect, Size;

import 'package:flutter/rendering.dart' show CustomPainter;

// ---------------------------------------------------------------------------
// a) 冻结导出：W1 逐字引用，禁止改名 / 改值。
// ---------------------------------------------------------------------------

/// Qt/src/NativeHudSearch.cpp:8 SearchInset。
const double kSearchInset = 53;

/// Qt/src/NativeHud.h:96 ResultListTop。
const double kSearchResultListTop = 328;

/// Qt/src/NativeHud.h:97 ResultListBottom。
const double kSearchResultListBottom = 758;

/// Qt/src/NativeHud.h:98 ResultRowHeight。
const double kSearchResultRowHeight = 72;

/// ResultListBottom - ResultListTop = 430（Qt/src/NativeHudSearch.cpp:134 视口高度）。
const double kSearchResultListHeight = kSearchResultListBottom - kSearchResultListTop;

// 其余 Qt 常量（同一真源，供本文件与宿主复用）。

/// Qt/src/NativeHudSearch.cpp:17 SearchTitleX。
const double kSearchTitleX = 107;

/// Qt/src/NativeHudSearch.cpp:18 SearchActionWidth。
const double kSearchActionWidth = 136;

/// Qt/src/NativeHudSearch.cpp:185 id 列的 fit 宽度上限。
const double kSearchRowIdWidth = 92;

/// Qt/src/NativeHudSearch.cpp:163 railX = x + width - 24。
const double kSearchRailRightInset = 24;

/// Qt/src/NativeHudSearch.cpp:166 轨道宽 3。
const double kSearchRailWidth = 3;

/// Qt/src/NativeHudSearch.cpp:164 railTop = viewport.top + 8。
const double kSearchRailTopInset = 8;

/// Qt/src/NativeHudSearch.cpp:165 railHeight = viewport.height - 16。
const double kSearchRailVerticalInset = 16;

/// Qt/src/HudScroll.h:51 rail() 的 minThumbHeight 默认值，检索列表取默认。
const double kSearchRailMinThumbHeight = 30;

/// Qt/src/NativeHudInput.cpp:92-95：检索列表把 ResultRowHeight 当作滚轮每步像素
/// （applyWheel(..., step, ResultRowHeight)），不是 HudScroll::DefaultWheelStep(60)。
const double kSearchRowWheelStep = kSearchResultRowHeight;

/// Qt/src/NativeHudSearch.cpp:184 行分隔线 alpha 0.16。
const double kSearchRowSeparatorOpacity = 0.16;

/// Qt/src/NativeHudSearch.cpp:169 轨道 ink@0.10。
const double kSearchRailTrackOpacity = 0.10;

/// Qt/src/NativeHudSearch.cpp:171 thumb ink@0.45。
const double kSearchRailThumbOpacity = 0.45;

/// Qt/src/NativeHudSearch.cpp:143 空态标题字号。
const double kSearchEmptyMessageSize = 18;

/// Qt/src/NativeHudSearch.cpp:146 空态提示字号。
const double kSearchEmptyHintSize = 12;

/// Qt/src/NativeHudSearch.cpp:143 空态标题 y 偏移（ResultListTop + 92）。
const double kSearchEmptyMessageOffsetY = 92;

/// Qt/src/NativeHudSearch.cpp:146 空态提示 y 偏移（ResultListTop + 128）。
const double kSearchEmptyHintOffsetY = 128;

/// Qt/src/NativeHudSearch.cpp:186 标题字号。
const double kSearchTitleSize = 18;

/// Qt/src/NativeHudSearch.cpp:185 编号字号。
const double kSearchIdSize = 10;

/// Qt/src/NativeHudSearch.cpp:199-201 标签字号。
const double kSearchTagSize = 8;

/// Qt/src/NativeHudSearch.cpp:201 标签 letterSpacing 0.06。
const double kSearchTagLetterSpacing = 0.06;

/// Qt/src/NativeHudSearch.cpp:202 明细字号。
const double kSearchDetailSize = 10;

/// Qt/src/NativeHudSearch.cpp:204 「查看 ↗」字号。
const double kSearchActionSize = 11;

/// Qt/src/NativeHudSearch.cpp:228 下划线 = y + size + 1（size 18 → 19）。
const double kSearchTitleUnderlineOffset = kSearchTitleSize + 1;

/// Qt/src/NativeHudSearch.cpp:228 下划线高度 2。
const double kSearchTitleUnderlineHeight = 2;

/// Qt/src/NativeHudSearch.cpp:210 行命中高度。
const double kSearchRowHitHeight = kSearchResultRowHeight;

/// Qt/src/NativeHudSearch.cpp:20-22 accent。
const SearchColor kSearchAccent = SearchColor(0.835, 0.639, 0.282);

/// Qt/src/NativeHudSearch.cpp:41 dark 标签底色。
const SearchColor kSearchTagFillDark = SearchColor(1, 1, 1, 0.07);

/// Qt/src/NativeHudSearch.cpp:41 light 标签底色。
const SearchColor kSearchTagFillLight = SearchColor(0.10, 0.11, 0.10, 0.05);

/// Qt/src/NativeHudController.cpp:93 group 行 album 字段文案。
const String kSearchGroupAlbumLabel = '点击展开分组';

/// Qt/src/NativeHudController.cpp:75 歌手缺失文案。
const String kSearchUnknownArtist = '未知歌手';

/// Qt/src/NativeHudController.cpp:81 专辑缺失文案。
const String kSearchUnknownAlbum = '未知专辑';

/// Qt/src/NativeHudController.cpp:104 group 行 artist 字段后缀。
const String kSearchGroupLoadedSuffix = ' 首已载入';

/// 行「查看 ↗」文案（Qt/src/NativeHudSearch.cpp:204）。
const String kSearchRowActionLabel = '查看 ↗';

/// 检索列表行；index 为原始列表下标（分组行固定 -1，Qt/src/NativeHudController.cpp:92）。
class SearchRow {
  const SearchRow({required this.index, required this.value});

  final int index;
  final Map<String, Object?> value;

  @override
  String toString() => 'SearchRow(index: $index, value: $value)';
}

/// Qt HUD 的 {r,g,b,a} double 四元组（Qt/src/NativeHudSearch.cpp:20-42）。
class SearchColor {
  const SearchColor(this.r, this.g, this.b, [this.a = 1]);

  final double r;
  final double g;
  final double b;
  final double a;

  /// faintInk(ink, alpha)（Qt/src/NativeHudSearch.cpp:30-34）。
  SearchColor withAlpha(double alpha) => SearchColor(r, g, b, alpha);

  /// HUD op 流里颜色是 0..1 的 double 四元组；渲染侧按 255 取整（四舍五入后夹取）。
  Color toColor() => Color.fromARGB(
        (a * 255).round().clamp(0, 255).toInt(),
        (r * 255).round().clamp(0, 255).toInt(),
        (g * 255).round().clamp(0, 255).toInt(),
        (b * 255).round().clamp(0, 255).toInt(),
      );

  @override
  bool operator ==(Object other) =>
      other is SearchColor && other.r == r && other.g == g && other.b == b && other.a == a;

  @override
  int get hashCode => Object.hash(r, g, b, a);

  @override
  String toString() => 'SearchColor($r, $g, $b, $a)';
}

/// mutedInk(ink) = ink 且 alpha 0.55（Qt/src/NativeHudSearch.cpp:24-28）。
SearchColor searchMutedInk(SearchColor ink) => ink.withAlpha(0.55);

/// faintInk(ink, alpha)（Qt/src/NativeHudSearch.cpp:30-34）。
SearchColor searchFaintInk(SearchColor ink, double alpha) => ink.withAlpha(alpha);

// ---------------------------------------------------------------------------
// QJsonValue 取值语义（Qt 的 toString()/toDouble() 只在类型匹配时给值）。
// ---------------------------------------------------------------------------

/// 等价 QJsonValue::toString()：非 string 类型返回空串（Qt 行为，不做 toString 泛化）。
String searchQtString(Object? value) => value is String ? value : '';

/// 等价 QJsonValue::toDouble()：非 num 类型返回 0。
double searchQtDouble(Object? value) => value is num ? value.toDouble() : 0;

/// 等价 QString::number(double, 'f', 0)：远离零四舍五入，且不带指数。
///
/// 合同要求 2.5 -> 3、-0.5 -> -1；Dart 的 toStringAsFixed 在二进制边界上的
/// 舍入方向与 Qt 的 printf %.0f 不完全一致，因此这里显式实现 half-away-from-zero。
String searchQtNumberFixed0(double value) {
  if (value.isNaN) {
    return 'nan';
  }
  if (value.isInfinite) {
    return value.isNegative ? '-inf' : 'inf';
  }
  final rounded = value < 0 ? (value - 0.5).ceilToDouble() : (value + 0.5).floorToDouble();
  return rounded.toStringAsFixed(0);
}

// ---------------------------------------------------------------------------
// c) 视口 / 可见范围 / 行矩形 / 滚动。
// ---------------------------------------------------------------------------

/// 结果视口：Rect(originX+53, originY+328, modalWidth-106, 430)。
/// Qt/src/NativeHudSearch.cpp:132-134 + Qt/src/NativeHud.cpp:188-191（state 的 searchList*）。
Rect searchResultViewport({
  required double originX,
  required double originY,
  required double modalWidth,
}) {
  return Rect.fromLTWH(
    originX + kSearchInset,
    originY + kSearchResultListTop,
    modalWidth - kSearchInset * 2,
    kSearchResultListHeight,
  );
}

/// 可见行区间（闭区间）。last < first 表示空区间。
class SearchVisibleRange {
  const SearchVisibleRange({required this.first, required this.last});

  /// rowCount == 0 时的空区间（Qt HudScroll::visibleRange 的 {} 等价）。
  static const SearchVisibleRange empty = SearchVisibleRange(first: 0, last: -1);

  final int first;
  final int last;

  bool get isEmpty => last < first;

  bool get isNotEmpty => last >= first;

  /// 区间内行数。
  int get count => isEmpty ? 0 : last - first + 1;

  /// 区间内的行下标，升序。
  List<int> get indices =>
      isEmpty ? const <int>[] : List<int>.generate(count, (offset) => first + offset);

  @override
  bool operator ==(Object other) =>
      other is SearchVisibleRange && other.first == first && other.last == last;

  @override
  int get hashCode => Object.hash(first, last);

  @override
  String toString() => 'SearchVisibleRange($first, $last)';
}

/// Qt/src/NativeHudSearch.cpp:153-155：
/// first = max(0, floor(scroll/72) - 1)，last = min(rowCount-1, ceil((scroll+vp)/72) + 1)。
SearchVisibleRange searchVisibleRange({
  required int rowCount,
  required double scroll,
  required double viewportHeight,
}) {
  if (rowCount <= 0) {
    return SearchVisibleRange.empty;
  }
  final first = math.max(0, (scroll / kSearchResultRowHeight).floor() - 1);
  final last =
      math.min(rowCount - 1, ((scroll + viewportHeight) / kSearchResultRowHeight).ceil() + 1);
  return SearchVisibleRange(first: first, last: last);
}

/// Qt/src/NativeHudSearch.cpp:255-257 + Qt/src/HudScroll.h:13-15。
double searchScrollMaximum(int rowCount, double viewportHeight) {
  return math.max(rowCount * kSearchResultRowHeight - viewportHeight, 0.0);
}

/// Qt/src/NativeHudSearch.cpp:139 的 clamp(searchScroll, 0, maximum)。
double searchClampScroll({
  required double scroll,
  required int rowCount,
  required double viewportHeight,
}) {
  final maximum = searchScrollMaximum(rowCount, viewportHeight);
  return scroll.clamp(0.0, maximum).toDouble();
}

/// Qt/src/HudScroll.h:21-26 applyWheel：distance 有效且非 0 时用它，否则 steps * stepPixels；
/// 结果 clamp 到 [0, maximum]。检索列表 stepPixels = ResultRowHeight = 72
/// （Qt/src/NativeHudInput.cpp:92-95 传入 ResultRowHeight）。
double searchApplyWheel({
  required double scroll,
  required int rowCount,
  required double viewportHeight,
  int steps = 1,
  double? distance,
  double stepPixels = kSearchRowWheelStep,
}) {
  final movement = (distance != null && distance != 0) ? distance : steps * stepPixels;
  return searchClampScroll(
    scroll: scroll + movement,
    rowCount: rowCount,
    viewportHeight: viewportHeight,
  );
}

/// Qt/src/NativeHudSearch.cpp:157：rowY = originY + ResultListTop + index*72 - scroll。
Rect searchRowRect(Rect viewport, int index, double scroll) {
  return Rect.fromLTWH(
    viewport.left,
    viewport.top + index * kSearchResultRowHeight - scroll,
    viewport.width,
    kSearchResultRowHeight,
  );
}

/// 行分隔线：rule(left, y + 71, usable, 0.16)（Qt/src/NativeHudSearch.cpp:184）。
Rect searchRowSeparator(Rect rowRect) {
  return Rect.fromLTWH(
    rowRect.left,
    rowRect.top + kSearchResultRowHeight - 1,
    rowRect.width,
    1,
  );
}

// ---------------------------------------------------------------------------
// d) 滚动轨（Qt/src/NativeHudSearch.cpp:163-172 + Qt/src/HudScroll.h:43-64）。
// ---------------------------------------------------------------------------

/// 轨道 + 可能为空的 thumb。
class SearchScrollRail {
  const SearchScrollRail({required this.track, required this.thumb});

  final Rect track;

  /// 内容不超过视口时为 null（HudScroll::rail 不返回 thumb）。
  final Rect? thumb;

  bool get visible => thumb != null;

  @override
  String toString() => 'SearchScrollRail(track: $track, thumb: $thumb)';
}

/// 轨道矩形：Rect(originX + modalWidth - 24, viewport.top + 8, 3, viewport.height - 16)。
Rect searchRailTrack({
  required double originX,
  required double modalWidth,
  required Rect viewport,
}) {
  return Rect.fromLTWH(
    originX + modalWidth - kSearchRailRightInset,
    viewport.top + kSearchRailTopInset,
    kSearchRailWidth,
    viewport.height - kSearchRailVerticalInset,
  );
}

/// HudScroll::rail 的等价实现：
///   range = max(contentHeight - viewportHeight, 0)
///   range <= 0 或 track.height <= 0 → 无 thumb
///   thumbHeight = clamp(track.height * viewportHeight / contentHeight,
///                       min(minThumbHeight, track.height), track.height)
///   thumbY = track.top + clamp(offset / range, 0, 1) * (track.height - thumbHeight)
SearchScrollRail searchScrollRail({
  required Rect track,
  required int rowCount,
  required double scroll,
  required double viewportHeight,
}) {
  final contentHeight = rowCount * kSearchResultRowHeight;
  final range = math.max(contentHeight - viewportHeight, 0.0);
  if (range <= 0 || track.height <= 0) {
    return SearchScrollRail(track: track, thumb: null);
  }
  final thumbHeight = (track.height * viewportHeight / contentHeight)
      .clamp(math.min(kSearchRailMinThumbHeight, track.height), track.height)
      .toDouble();
  final progress = (scroll / range).clamp(0.0, 1.0).toDouble();
  final thumbY = track.top + progress * (track.height - thumbHeight);
  return SearchScrollRail(
    track: track,
    thumb: Rect.fromLTWH(track.left, thumbY, track.width, thumbHeight),
  );
}

// ---------------------------------------------------------------------------
// e) 空态（Qt/src/NativeHudSearch.cpp:141-148）。
// ---------------------------------------------------------------------------

/// 空态提示文案：local 与非 local 两个分支逐字取自 Qt 源码。
String searchEmptyHint({required bool localMusic}) {
  return localMusic ? '在文件夹管理中导入音乐后即可检索。' : '输入歌曲、歌手、专辑或歌单名称后按 ENTER。';
}

/// 空态标题位置：(viewport.left, viewport.top + 92)。
Offset searchEmptyMessagePosition(Rect viewport) =>
    Offset(viewport.left, viewport.top + kSearchEmptyMessageOffsetY);

/// 空态提示位置：(viewport.left, viewport.top + 128)。
Offset searchEmptyHintPosition(Rect viewport) =>
    Offset(viewport.left, viewport.top + kSearchEmptyHintOffsetY);

// ---------------------------------------------------------------------------
// f) 行内容（Qt/src/NativeHudSearch.cpp:175-211）。
// ---------------------------------------------------------------------------

/// titleWidth = modalWidth - 308（Qt/src/NativeHudSearch.cpp:179）。
double searchRowTitleWidth(double modalWidth) => modalWidth - 308;

/// 行标题原文（命中 label 用原文，不用 fit 后的结果；Qt/src/NativeHudSearch.cpp:182,210）。
String searchRowTitle(Map<String, Object?> value) => searchQtString(value['title']);

/// 编号列文本（Qt/src/NativeHudSearch.cpp:185）。
String searchRowIdText(Map<String, Object?> value) => searchQtString(value['id']);

/// kind 转大写，空则 SONG（Qt/src/NativeHudSearch.cpp:188-191）。
String searchRowKind(Map<String, Object?> value) {
  final kind = searchQtString(value['kind']).toUpperCase();
  return kind.isEmpty ? 'SONG' : kind;
}

/// 明细：artist 非空否则 album；含 playCount 键则追加 " / N 次播放"。
/// Qt/src/NativeHudSearch.cpp:192-198。
String searchRowDetail(Map<String, Object?> value) {
  var detail = searchQtString(value['artist']);
  if (detail.isEmpty) {
    detail = searchQtString(value['album']);
  }
  if (value.containsKey('playCount')) {
    detail += ' / ${searchQtNumberFixed0(searchQtDouble(value['playCount']))} 次播放';
  }
  return detail;
}

/// 标签底色（Qt/src/NativeHudSearch.cpp:40-42）。
SearchColor searchTagFill(bool dark) => dark ? kSearchTagFillDark : kSearchTagFillLight;

/// tagWidth = glyphWidth(kind, 8, regular) + 10（Qt/src/NativeHudSearch.cpp:199）。
double searchRowTagWidth({
  required Map<String, Object?> value,
  required double Function(String text, double size, String weight) glyphWidth,
}) {
  return glyphWidth(searchRowKind(value), kSearchTagSize, 'regular') + 10;
}

/// 一行里所有绘制锚点（全部舞台坐标，Qt/src/NativeHudSearch.cpp:184-204）。
class SearchRowLayout {
  const SearchRowLayout({
    required this.rowRect,
    required this.separator,
    required this.idPosition,
    required this.titlePosition,
    required this.tagRect,
    required this.tagTextPosition,
    required this.detailPosition,
    required this.detailMaxWidth,
    required this.actionPosition,
  });

  final Rect rowRect;
  final Rect separator;
  final Offset idPosition;
  final Offset titlePosition;
  final Rect tagRect;
  final Offset tagTextPosition;
  final Offset detailPosition;

  /// fit(detail, 10, titleWidth - tagWidth - 8)（Qt/src/NativeHudSearch.cpp:202）。
  final double detailMaxWidth;

  final Offset actionPosition;
}

/// 计算一行的全部锚点；rowY 已含滚动偏移（= viewport.top + index*72 - scroll）。
SearchRowLayout searchRowLayout({
  required Rect viewport,
  required double modalWidth,
  required double rowY,
  required double tagWidth,
  required double titleWidth,
}) {
  final left = viewport.left;
  return SearchRowLayout(
    rowRect: Rect.fromLTWH(left, rowY, viewport.width, kSearchResultRowHeight),
    separator: Rect.fromLTWH(left, rowY + kSearchResultRowHeight - 1, viewport.width, 1),
    idPosition: Offset(left, rowY + 20),
    titlePosition: Offset(left + kSearchTitleX, rowY + 11),
    tagRect: Rect.fromLTWH(left + kSearchTitleX, rowY + 40, tagWidth, 14),
    tagTextPosition: Offset(left + kSearchTitleX + 5, rowY + 41),
    detailPosition: Offset(left + kSearchTitleX + tagWidth + 8, rowY + 40),
    detailMaxWidth: titleWidth - tagWidth - 8,
    // x + width - SearchActionWidth，x 为弹窗左边界 = viewport.left - SearchInset。
    actionPosition: Offset(left - kSearchInset + modalWidth - kSearchActionWidth, rowY + 20),
  );
}

/// 行命中矩形：(viewport.left, rowY, viewport.width, 72)（Qt/src/NativeHudSearch.cpp:210）。
Rect searchRowHitRect(Rect viewport, double rowY) {
  return Rect.fromLTWH(viewport.left, rowY, viewport.width, kSearchRowHitHeight);
}

/// Qt HudScroll::clipHits：行命中必须先与视口求交，空交集丢弃（Qt/src/HudScroll.h:66-88）。
Rect? searchClipRowHit(Rect hitRect, Rect viewport) {
  final clipped = hitRect.intersect(viewport);
  return clipped.isEmpty ? null : clipped;
}

// ---------------------------------------------------------------------------
// h) 百分号编码（QUrl::toPercentEncoding / fromPercentEncoding）。
// ---------------------------------------------------------------------------

/// QUrl::toPercentEncoding 等价：仅 A-Z a-z 0-9 - _ . ~ 不编码，其余按 UTF-8
/// 逐字节 %XX（十六进制大写），空格必须是 %20 而不是 +。
String percentEncode(String input) {
  final buffer = StringBuffer();
  for (final byte in utf8.encode(input)) {
    if (_isUnreservedByte(byte)) {
      buffer.writeCharCode(byte);
    } else {
      buffer.write('%');
      buffer.write(byte.toRadixString(16).toUpperCase().padLeft(2, '0'));
    }
  }
  return buffer.toString();
}

/// percentEncode 的严格逆函数：非法 %XX、非 ASCII 字面量、非法 UTF-8 都抛 FormatException。
///
/// 与 Qt fromPercentEncoding 的差别只在错误分支：Qt 宽容替换 U+FFFD，无法构成往返；
/// 合同要求严格逆，因此这里拒绝而不是替换。'+' 按字面量保留（空格只由 %20 表示）。
String percentDecode(String input) {
  final bytes = <int>[];
  for (var index = 0; index < input.length; index++) {
    final unit = input.codeUnitAt(index);
    if (unit == 0x25) {
      if (index + 2 >= input.length) {
        throw const FormatException('percentDecode: truncated percent escape');
      }
      final high = _hexValue(input.codeUnitAt(index + 1));
      final low = _hexValue(input.codeUnitAt(index + 2));
      if (high < 0 || low < 0) {
        throw const FormatException('percentDecode: invalid percent escape');
      }
      bytes.add(high * 16 + low);
      index += 2;
    } else {
      if (unit > 0x7F) {
        throw const FormatException('percentDecode: non-ASCII literal');
      }
      bytes.add(unit);
    }
  }
  return utf8.decode(bytes);
}

bool _isUnreservedByte(int byte) {
  return (byte >= 0x41 && byte <= 0x5A) || // A-Z
      (byte >= 0x61 && byte <= 0x7A) || // a-z
      (byte >= 0x30 && byte <= 0x39) || // 0-9
      byte == 0x2D || // -
      byte == 0x5F || // _
      byte == 0x2E || // .
      byte == 0x7E; // ~
}

int _hexValue(int unit) {
  if (unit >= 0x30 && unit <= 0x39) {
    return unit - 0x30;
  }
  if (unit >= 0x41 && unit <= 0x46) {
    return unit - 0x41 + 10;
  }
  if (unit >= 0x61 && unit <= 0x66) {
    return unit - 0x61 + 10;
  }
  return -1;
}

// ---------------------------------------------------------------------------
// g) 行动作（Qt/src/NativeHudSearch.cpp:206-210）。
// ---------------------------------------------------------------------------

/// group 行 → music:expand:<percentEncode(key)>；其余 → music:result:<lane>:<index>。
String searchRowAction(SearchRow row, int lane) {
  final value = row.value;
  if (searchQtString(value['kind']) == 'group') {
    return 'music:expand:${percentEncode(searchQtString(value['key']))}';
  }
  return 'music:result:$lane:${row.index}';
}

// ---------------------------------------------------------------------------
// i) 标题匹配下划线（Qt/src/NativeHudSearch.cpp:213-230）。
// ---------------------------------------------------------------------------

/// 标题匹配结果；index < 0 表示未命中。
class SearchTitleMatch {
  const SearchTitleMatch({
    required this.index,
    required this.prefixWidth,
    required this.matchWidth,
  });

  static const SearchTitleMatch none =
      SearchTitleMatch(index: -1, prefixWidth: 0, matchWidth: 0);

  final int index;
  final double prefixWidth;
  final double matchWidth;
}

/// 与 Qt QString::indexOf(query, 0, Qt::CaseInsensitive) 等价：逐 UTF-16 单元折叠大小写后
/// 子串搜索，因此返回的下标与 Dart String.substring 的下标同构（都按 UTF-16 单元计数）。
/// Qt 用 QString::left/mid 也是 UTF-16 单元切片，故两侧 substring 完全同构。
SearchTitleMatch searchTitleMatch({
  required String shown,
  required String query,
  required double Function(String text, double size, String weight) glyphWidth,
}) {
  if (query.isEmpty) {
    return SearchTitleMatch.none;
  }
  final index = searchIndexOfCaseInsensitive(shown, query);
  if (index < 0) {
    return SearchTitleMatch.none;
  }
  final prefixWidth = glyphWidth(shown.substring(0, index), kSearchTitleSize, 'demibold');
  final matchWidth = glyphWidth(
    shown.substring(index, index + query.length),
    kSearchTitleSize,
    'demibold',
  );
  return SearchTitleMatch(
    index: index,
    prefixWidth: prefixWidth,
    matchWidth: matchWidth > 0 ? matchWidth : 0.0,
  );
}

/// 逐 UTF-16 单元的大小写折叠子串搜索（对齐 Qt 的 CaseInsensitive indexOf）。
int searchIndexOfCaseInsensitive(String haystack, String needle) {
  if (needle.isEmpty) {
    return 0;
  }
  final needleLength = needle.length;
  final limit = haystack.length - needleLength;
  for (var start = 0; start <= limit; start++) {
    var matched = true;
    for (var offset = 0; offset < needleLength; offset++) {
      if (!_sameFold(haystack.codeUnitAt(start + offset), needle.codeUnitAt(offset))) {
        matched = false;
        break;
      }
    }
    if (matched) {
      return start;
    }
  }
  return -1;
}

bool _sameFold(int left, int right) {
  if (left == right) {
    return true;
  }
  // 代理对半元不做折叠，避免 fromCharCode 处理孤立代理时行为不定。
  if ((left >= 0xD800 && left <= 0xDFFF) || (right >= 0xD800 && right <= 0xDFFF)) {
    return false;
  }
  return String.fromCharCode(left).toLowerCase() == String.fromCharCode(right).toLowerCase();
}

/// 下划线矩形：matchWidth > 0 时 fill(x + prefixWidth, y + 19, matchWidth, 2)。
Rect? searchTitleUnderline({
  required double x,
  required double y,
  required SearchTitleMatch match,
}) {
  if (match.matchWidth <= 0) {
    return null;
  }
  return Rect.fromLTWH(
    x + match.prefixWidth,
    y + kSearchTitleUnderlineOffset,
    match.matchWidth,
    kSearchTitleUnderlineHeight,
  );
}

// ---------------------------------------------------------------------------
// j) 分组派生（Qt/src/NativeHudController.cpp:183-260）。
// ---------------------------------------------------------------------------

/// 一个分组：key 是 value['key']，indices 是按原始 index 顺序保留的行号。
class SearchGroup {
  const SearchGroup({required this.key, required this.title, required this.indices});

  final String key;
  final String title;
  final List<int> indices;

  @override
  String toString() => 'SearchGroup($key, $title, $indices)';
}

/// 分组派生结果；rows 是最终展示列表，groups 仅在分组模式下非空。
class SearchGrouping {
  const SearchGrouping({required this.rows, required this.groups, required this.grouped});

  final List<SearchRow> rows;
  final List<SearchGroup> groups;
  final bool grouped;

  /// expand 动作需要的分组；找不到返回 null（Qt 找不到 group 时只改 activeGroup）。
  SearchGroup? groupFor(String key) {
    for (final group in groups) {
      if (group.key == key) {
        return group;
      }
    }
    return null;
  }
}

/// Qt NativeHud::rows(lane) 的等价实现。
///
/// [items] 的 index 就是原始列表下标；[groupBy] 取 none/artist/album；
/// [filter] 为 modal==saved 时已经 toLowerCase 的过滤词（Qt controller:188）。
/// 分组模式下非 song 行不参与分组，也不出现在结果里（Qt controller:196-198 的 continue）。
/// 本函数是纯函数：Qt controller 在 groupLane == lane 时回写 music.groupIndices 的副作用
/// 由宿主负责（用 [SearchGrouping.groupFor] 取 indices 写回），这里不持有控制器状态。
SearchGrouping deriveSearchGrouping({
  required List<SearchRow> items,
  required String groupBy,
  String activeGroup = '',
  String? filter,
}) {
  final visible = <SearchRow>[];
  for (final row in items) {
    if (filter == null || filter.isEmpty) {
      visible.add(row);
      continue;
    }
    final haystack = (searchQtString(row.value['title']) +
            searchQtString(row.value['artist']) +
            searchQtString(row.value['id']))
        .toLowerCase();
    if (haystack.contains(filter)) {
      visible.add(row);
    }
  }

  var hasSong = false;
  for (final row in visible) {
    if (searchQtString(row.value['kind']) == 'song') {
      hasSong = true;
      break;
    }
  }
  if (groupBy == 'none' || !hasSong) {
    return SearchGrouping(
      rows: List<SearchRow>.unmodifiable(visible),
      groups: const <SearchGroup>[],
      grouped: false,
    );
  }

  final groups = <SearchRow>[];
  final groupIndices = <List<int>>[];
  final entries = <List<SearchRow>>[];
  final groupTitles = <String>[];
  final groupKeys = <String>[];
  final indices = <String, int>{};

  for (final row in visible) {
    final value = row.value;
    if (searchQtString(value['kind']) != 'song') {
      continue;
    }
    // 同一行内同 label 去重（Qt controller:213 的 QSet seen，先到先得）。
    final labels = <String, String>{};
    if (groupBy == 'artist') {
      final artists = value['artists'];
      if (artists is List) {
        for (final entry in artists) {
          final artist = entry is Map ? entry : const <String, Object?>{};
          final id = searchQtString(artist['id']);
          final name = searchQtString(artist['name']);
          labels.putIfAbsent(id.isEmpty ? 'name:$name' : 'artist:$id', () => name);
        }
      }
      if (labels.isEmpty) {
        final name = searchQtString(value['artist']);
        labels['name:$name'] = name.isEmpty ? kSearchUnknownArtist : name;
      }
    } else {
      final id = searchQtString(value['albumID']);
      final album = searchQtString(value['album']);
      labels[id.isEmpty ? 'album-name:$album' : 'album:$id'] =
          album.isEmpty ? kSearchUnknownAlbum : album;
    }

    labels.forEach((label, title) {
      final existing = indices[label];
      final groupIndex = existing ?? groups.length;
      if (existing == null) {
        indices[label] = groupIndex;
        groups.add(SearchRow(
          index: -1,
          value: <String, Object?>{
            'kind': 'group',
            'key': label,
            'title': title,
            'album': kSearchGroupAlbumLabel,
          },
        ));
        entries.add(<SearchRow>[]);
        groupIndices.add(<int>[]);
        groupTitles.add(title);
        groupKeys.add(label);
      }
      entries[groupIndex].add(row);
      groupIndices[groupIndex].add(row.index);
    });
  }

  // Qt controller:233-236 第二遍写入 group 行的 id / artist 字段。
  for (var index = 0; index < groups.length; index++) {
    final count = groupIndices[index].length;
    groups[index].value['id'] = count.toString();
    groups[index].value['artist'] = '$count$kSearchGroupLoadedSuffix';
  }

  final groupList = <SearchGroup>[
    for (var index = 0; index < groups.length; index++)
      SearchGroup(
        key: groupKeys[index],
        title: groupTitles[index],
        indices: List<int>.unmodifiable(groupIndices[index]),
      ),
  ];

  List<SearchRow> rows;
  if (activeGroup.isEmpty) {
    rows = groups;
  } else {
    final groupIndex = indices[activeGroup];
    // Qt entries.value(indices.value(activeGroup, -1))：找不到即空列表。
    rows = groupIndex == null ? const <SearchRow>[] : entries[groupIndex];
  }

  return SearchGrouping(
    rows: List<SearchRow>.unmodifiable(rows),
    groups: List<SearchGroup>.unmodifiable(groupList),
    grouped: true,
  );
}

/// 只取展示列表的便捷入口（合同 j 的返回形状）。
List<SearchRow> deriveSearchRows({
  required List<SearchRow> items,
  required String groupBy,
  String activeGroup = '',
  String? filter,
}) {
  return deriveSearchGrouping(
    items: items,
    groupBy: groupBy,
    activeGroup: activeGroup,
    filter: filter,
  ).rows;
}

// ---------------------------------------------------------------------------
// k) 滚动状态与自动补载（Qt/src/NativeHudSearch.cpp:259-281）。
// ---------------------------------------------------------------------------

/// ensureSearchFilled 的判定结果。
class SearchAutoFillDecision {
  const SearchAutoFillDecision({
    required this.accepted,
    required this.autoFillSize,
    required this.needLoadMore,
    required this.shouldLoadMore,
  });

  /// 守卫全通过且 rowCount > autoFillSize（Qt 已把 autoFillSize 更新为 rowCount）。
  final bool accepted;

  /// 判定后的 autoFillSize（未被接受时保持原值）。
  final int autoFillSize;

  /// rowCount * 72 < 430（Qt/src/NativeHudSearch.cpp:278）。
  final bool needLoadMore;

  /// 只有 accepted 时 Qt 才会走到 loadMoreSource(0)，故实际触发取合取。
  final bool shouldLoadMore;
}

/// 检索/个人库共用的滚动状态（Qt/src/NativeHud.h:99-103）。
class SearchResultsState {
  SearchResultsState({
    this.searchScroll = 0,
    this.searchRowCount = 0,
    this.autoFillSize = -1,
    this.savedScroll = 0,
    this.savedRowCount = 0,
    this.savedAutoFillSize = -1,
  });

  double searchScroll;
  int searchRowCount;
  int autoFillSize;
  double savedScroll;
  int savedRowCount;
  int savedAutoFillSize;

  SearchAutoFillDecision? _lastAutoFill;

  /// 最近一次 evaluateAutoFill / shouldAutoFill 的完整判定。
  SearchAutoFillDecision? get lastAutoFill => _lastAutoFill;

  /// Qt resetResultViews（Qt/src/NativeHudSearch.cpp:259-266）：六字段复位。
  void resetResultViews() {
    searchScroll = 0;
    searchRowCount = 0;
    autoFillSize = -1;
    savedScroll = 0;
    savedRowCount = 0;
    savedAutoFillSize = -1;
  }

  /// Qt ensureSearchFilled（Qt/src/NativeHudSearch.cpp:268-281）。
  SearchAutoFillDecision evaluateAutoFill({
    required bool modalIsSearch,
    required bool closing,
    required String query,
    required String keyword,
    required bool sourceLoading,
    required bool hasMore,
    required int rowCount,
  }) {
    final needsMore = rowCount * kSearchResultRowHeight < kSearchResultListHeight;
    final guardOpen =
        modalIsSearch && !closing && query.trim() == keyword && !sourceLoading && hasMore;
    if (!guardOpen || rowCount <= autoFillSize) {
      return _lastAutoFill = SearchAutoFillDecision(
        accepted: false,
        autoFillSize: autoFillSize,
        needLoadMore: needsMore,
        shouldLoadMore: false,
      );
    }
    autoFillSize = rowCount;
    return _lastAutoFill = SearchAutoFillDecision(
      accepted: true,
      autoFillSize: autoFillSize,
      needLoadMore: needsMore,
      shouldLoadMore: needsMore,
    );
  }

  /// 合同 k 的字面入口：仅当守卫全通过且 rowCount > autoFillSize 时返回 true，
  /// 并把 autoFillSize 更新为 rowCount；needLoadMore 见 [lastAutoFill]。
  bool shouldAutoFill({
    required bool modalIsSearch,
    required bool closing,
    required String query,
    required String keyword,
    required bool sourceLoading,
    required bool hasMore,
    required int rowCount,
  }) {
    return evaluateAutoFill(
      modalIsSearch: modalIsSearch,
      closing: closing,
      query: query,
      keyword: keyword,
      sourceLoading: sourceLoading,
      hasMore: hasMore,
      rowCount: rowCount,
    ).accepted;
  }
}

// ---------------------------------------------------------------------------
// l) 绘制适配层：可注入端口 + CustomPainter。
// ---------------------------------------------------------------------------

/// 绘制端口。所有字形宽度、截断与文字绘制都在实现方完成（真实 advance / 1.044 baseline），
/// 命中回调保持 Qt hit 六字段原序 (x, y, width, height, action, label)。
///
/// 方法顺序与 Qt HUD op 流一致：save → clip → fill/text/hit → restore。
abstract class SearchResultsPort {
  double glyphWidth(String text, double size, String weight);

  /// fit(value, size, width, weight)（Qt/src/NativeHud.cpp:48）。
  String fit(String text, double size, double maxWidth, String weight);

  void save();

  void clip(Rect rect);

  void restore();

  void fill(Rect rect, SearchColor color);

  /// text(value, x, y, size, weight, tracking, color)（Qt/src/NativeHud.cpp:40-43）。
  void text(
    String text,
    double x,
    double y,
    double size,
    String weight,
    double letterSpacing,
    SearchColor color,
  );

  /// Qt NativeHud::hit：六字段原序。
  void hit(double x, double y, double width, double height, String action, String label);
}

/// 检索结果层的绘制适配器。
///
/// 只产出与 Qt HUD op 流等价的指令；画布、字形 advance 与 baseline 由端口实现方持有，
/// 所以本文件不会伪造字体度量（合同：baseline 1.044 由宿主端口负责）。
class SearchResultsLayer extends CustomPainter {
  const SearchResultsLayer({
    required this.port,
    required this.originX,
    required this.originY,
    required this.modalWidth,
    required this.rows,
    required this.scroll,
    required this.lane,
    required this.ink,
    required this.dark,
    required this.localMusic,
    required this.emptyMessage,
    required this.query,
  });

  final SearchResultsPort port;
  final double originX;
  final double originY;
  final double modalWidth;
  final List<SearchRow> rows;
  final double scroll;
  final int lane;
  final SearchColor ink;
  final bool dark;
  final bool localMusic;

  /// sourceMessage(0)（Qt/src/NativeHudSearch.cpp:142）。
  final String emptyMessage;

  /// Qt m_music->keyword：已提交的检索词（不是输入框实时文本），
  /// 只用于行标题高亮（NativeHudSearch.cpp:209 传 keyword）。
  final String query;

  Rect get viewport =>
      searchResultViewport(originX: originX, originY: originY, modalWidth: modalWidth);

  double get maximumScroll => searchScrollMaximum(rows.length, viewport.height);

  @override
  void paint(Canvas canvas, Size size) {
    // 端口实现方自行持有 canvas；这里只负责按 Qt 顺序产出指令。
    draw(port);
  }

  /// 与 paint 等价但不经过画布，便于宿主与单元测试直接驱动端口。
  void draw(SearchResultsPort port) {
    final area = viewport;
    final muted = searchMutedInk(ink);
    if (rows.isEmpty) {
      // Qt/src/NativeHudSearch.cpp:141-147：空态直接返回，不画轨道也不发命中。
      port.text(
        port.fit(emptyMessage, kSearchEmptyMessageSize, area.width, 'demibold'),
        area.left,
        area.top + kSearchEmptyMessageOffsetY,
        kSearchEmptyMessageSize,
        'demibold',
        0,
        ink,
      );
      port.text(
        port.fit(
          searchEmptyHint(localMusic: localMusic),
          kSearchEmptyHintSize,
          area.width,
          'regular',
        ),
        area.left,
        area.top + kSearchEmptyHintOffsetY,
        kSearchEmptyHintSize,
        'regular',
        0,
        muted,
      );
      return;
    }

    final effectiveScroll = searchClampScroll(
      scroll: scroll,
      rowCount: rows.length,
      viewportHeight: area.height,
    );
    final range = searchVisibleRange(
      rowCount: rows.length,
      scroll: effectiveScroll,
      viewportHeight: area.height,
    );
    final titleWidth = searchRowTitleWidth(modalWidth);

    port.save();
    port.clip(area);
    for (final index in range.indices) {
      _drawRow(port, area, index, effectiveScroll, titleWidth, muted);
    }
    port.restore();

    _drawRail(port, area, effectiveScroll);
  }

  void _drawRow(
    SearchResultsPort port,
    Rect area,
    int index,
    double scroll,
    double titleWidth,
    SearchColor muted,
  ) {
    final row = rows[index];
    final value = row.value;
    final rowY = area.top + index * kSearchResultRowHeight - scroll;
    final kind = searchRowKind(value);
    final tagWidth = searchRowTagWidth(value: value, glyphWidth: port.glyphWidth);
    final layout = searchRowLayout(
      viewport: area,
      modalWidth: modalWidth,
      rowY: rowY,
      tagWidth: tagWidth,
      titleWidth: titleWidth,
    );

    // rule(left, y + 71, usable, 0.16)
    port.fill(layout.separator, searchFaintInk(ink, kSearchRowSeparatorOpacity));
    port.text(
      port.fit(searchRowIdText(value), kSearchIdSize, kSearchRowIdWidth, 'regular'),
      layout.idPosition.dx,
      layout.idPosition.dy,
      kSearchIdSize,
      'regular',
      0,
      muted,
    );

    final shown = port.fit(searchRowTitle(value), kSearchTitleSize, titleWidth, 'demibold');
    port.text(
      shown,
      layout.titlePosition.dx,
      layout.titlePosition.dy,
      kSearchTitleSize,
      'demibold',
      0,
      ink,
    );
    final match = searchTitleMatch(shown: shown, query: query, glyphWidth: port.glyphWidth);
    final underline = searchTitleUnderline(
      x: layout.titlePosition.dx,
      y: layout.titlePosition.dy,
      match: match,
    );
    if (underline != null) {
      port.fill(underline, kSearchAccent);
    }

    port.fill(layout.tagRect, searchTagFill(dark));
    port.text(
      kind,
      layout.tagTextPosition.dx,
      layout.tagTextPosition.dy,
      kSearchTagSize,
      'regular',
      kSearchTagLetterSpacing,
      muted,
    );
    port.text(
      port.fit(searchRowDetail(value), kSearchDetailSize, layout.detailMaxWidth, 'regular'),
      layout.detailPosition.dx,
      layout.detailPosition.dy,
      kSearchDetailSize,
      'regular',
      0,
      muted,
    );
    port.text(
      kSearchRowActionLabel,
      layout.actionPosition.dx,
      layout.actionPosition.dy,
      kSearchActionSize,
      'regular',
      0,
      muted,
    );

    // 命中按绘制顺序最后 append，且与视口求交（Qt HudScroll::clipHits）。
    final hitRect = searchClipRowHit(searchRowHitRect(area, rowY), area);
    if (hitRect != null) {
      port.hit(
        hitRect.left,
        hitRect.top,
        hitRect.width,
        hitRect.height,
        searchRowAction(row, lane),
        searchRowTitle(value),
      );
    }
  }

  void _drawRail(SearchResultsPort port, Rect area, double effectiveScroll) {
    final track = searchRailTrack(originX: originX, modalWidth: modalWidth, viewport: area);
    final rail = searchScrollRail(
      track: track,
      rowCount: rows.length,
      scroll: effectiveScroll,
      viewportHeight: area.height,
    );
    port.fill(track, searchFaintInk(ink, kSearchRailTrackOpacity));
    final thumb = rail.thumb;
    if (thumb != null) {
      port.fill(thumb, searchFaintInk(ink, kSearchRailThumbOpacity));
    }
  }

  @override
  bool shouldRepaint(covariant SearchResultsLayer oldDelegate) {
    return oldDelegate.port != port ||
        oldDelegate.originX != originX ||
        oldDelegate.originY != originY ||
        oldDelegate.modalWidth != modalWidth ||
        oldDelegate.rows != rows ||
        oldDelegate.scroll != scroll ||
        oldDelegate.lane != lane ||
        oldDelegate.ink != ink ||
        oldDelegate.dark != dark ||
        oldDelegate.localMusic != localMusic ||
        oldDelegate.emptyMessage != emptyMessage ||
        oldDelegate.query != query;
  }
}
