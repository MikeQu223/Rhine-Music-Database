/// 竖屏（compact）HUD 的资料库内页：**收藏/歌单内页** 与 **检索结果页**。
///
/// 真源：
///   `Qt/src/ResponsiveHudPages.cpp:289-...` `collection()`：封面方图 + 标题/说明 +
///   播放全部主按钮 + `visibleRows` 裁剪的曲目行；
///   `Qt/src/ResponsiveHudPages.cpp:855-990` `library()` 的 `search` 分支：
///   检索框 + `field("input")` + 四等分 tab（amber 指示条）+ `INDEX / N` 结果区
///   （本移植按竖屏规范把检索框底色换成 raised，字段名固定为 `search`）；
///   `Qt/src/ResponsiveHudCanvas.cpp` 的 `header()` / `row()` / `visibleRows()`。
///
/// 与 `portrait_canvas.dart` 一样，这里只把「一次排版」发射成命令流 + 命中表：
/// 滚动位置、tab 切换、检索输入、播放动作全部归宿主（BasicHudSurface / basic_app）。
/// 因此列表只画第一屏，超出部分交给宿主的 `beginContent` 裁剪区间去滚动。
///
/// 纯 Dart：不 import Flutter（命中/命令流与渲染树无关），也不新建类。
library;

import 'dart:math' as math;
import 'dart:ui' show Rect;

import 'portrait_canvas.dart';

/// 曲目行行高（`Qt/src/ResponsiveHudCanvas.cpp` `row()` 的 68）。
const double _rowHeight = 68;

/// 检索结果行行高：比曲目行矮，因为只有标题/副标/时长三行信息。
const double _resultRowHeight = 60;

/// 393 网格的左右页边距（Qt 全站 20 / 373）。
const double _left = 20;
double _rightOf(PortraitCanvas c) => c.gridWidth - 20;
/// 正文宽度：随页宽走（DPI 适配后页宽比 393 宽），左右各留 20 网格。
double _contentWidth(PortraitCanvas c) => c.gridWidth - 40;

/// 收藏/歌单内页。返回前必须调用 `c.finish()`。
void paintPortraitCollectionPage(
  PortraitCanvas c, {
  required String title, // 如「我喜欢的音乐」
  required String subtitle, // 如「共 42 首 · 歌单」
  required String cover, // 真实封面 key，空串 = 无
  required List<(String title, String artist, String stamp, String kind)> rows,
  required int index,
  required bool canPlayAll,
  required String emptyNotice,
  // 滚动窗口（条目单位，可为小数）：专辑/歌单目录里曲目多于可视行时必须能滚。
  // 旧实现按 `i * _rowHeight` 从 listTop 硬排，超出裁剪区的行直接被裁掉且无法滚动，
  // 于是进一张 10 首的专辑只看得到头 4 首。
  double position = 0,
}) {
  final double h = c.height;
  final int total = rows.length;

  // 内页沿用参考实现的纵向阅读渐变（ResponsiveHudLayout::arrange 的 stops
  // .93/.86/.66/.95），否则 3D 场景会透过行间缝隙。
  _pageWash(c);
  c.header(title, back: true);

  final double top = math.min(126.0, h * .22);
  final double bottom = _pageBottom(c, top);
  final double available = math.max(0.0, bottom - top);

  // 封面方图：参考 113 网格单位（Qt `{20, y + 4, 113, 113}`），小视口按可用高度收缩。
  final double coverSize = math.max(64.0, math.min(113.0, available * .24));
  final Rect coverRect = Rect.fromLTWH(_left, top, coverSize, coverSize);
  if (cover.isEmpty) {
    // 没有真实封面就留空槽 + 细边，绝不画假图。
    c.fill(coverRect, c.surface);
    c.border(coverRect, c.line);
  } else {
    c.image(cover, coverRect);
  }

  // 文本列：标题最多两行，副标贴封面底部（参考图「标题在上、说明在下」）。
  final double textX = math.min(coverRect.right + 16, 300.0);
  final double textWidth = math.max(0.0, _rightOf(c) - textX);
  final double titleEnd = c.paragraph(
    title,
    textX,
    top + 2,
    size: 18,
    width: textWidth,
    weight: 'demibold',
    maximumLines: 2,
    lineSpacing: 1.2,
  );
  final double subtitleY =
      math.min(math.max(titleEnd + 2, coverRect.bottom - 18), math.max(top, bottom - 12));
  c.text(subtitle, textX, subtitleY, size: 10, width: textWidth, color: c.muted);

  double y = coverRect.bottom + 12;

  // 「播放全部」主色按钮（Qt collection() 的 playAll）；只在宿主确认可播时出现。
  if (canPlayAll && y + 42 <= bottom) {
    c.button(Rect.fromLTWH(_left, y, _contentWidth(c), 42), '▶  播放全部', 'music:play-loaded', primary: true);
    y += 52;
  }

  if (y + 26 <= bottom) {
    c.section(y, '曲目目录', 'TRACK INDEX');
  }
  final double listTop = math.min(y + 28, bottom);

  // 底部提示行：共 N 首 + 当前下标。列表裁剪到这一行之上；
  // 视口太矮时整行让位，宁可少一条提示也不压到曲目行上。
  final bool roomForFooter = bottom - 30 - listTop >= 18;
  final double clipBottom = roomForFooter ? bottom - 30 : bottom;
  if (roomForFooter) {
    c.fill(Rect.fromLTWH(_left, bottom - 30, _contentWidth(c), .6), c.line);
    c.text('共 $total 首', _left, bottom - 22, size: 9, width: 200, color: c.muted);
    if (total > 0) {
      c.rightText('${_pad(index + 1)} / ${_pad(total)}', _rightOf(c), bottom - 22, 9, 'regular', c.muted);
    }
  }

  // 第一屏曲目：只画可见区间，滚动由宿主负责（Qt 里是 y = 158 - m_scroll 的同一份排版）。
  if (clipBottom - listTop >= 24) {
    final double restoreBottom = c.contentBottom;
    c.contentBottom = clipBottom;
    c.beginContent(listTop);
    if (rows.isEmpty) {
      if (emptyNotice.isNotEmpty) {
        c.text(emptyNotice, _left, listTop + 12, size: 11, width: _contentWidth(c), color: c.muted);
      }
    } else {
      // 与主页列表同一套窗口语义（见 portrait_layout.dart 的 `_list()`）：当前行钉在
      // 首槽，位置连续增长；行窗口是相对当前 -1 .. +3，多一点余量给亚像素滑动。
      final double slotY = listTop + _rowHeight * position.clamp(0.0, 1.0);
      final int first = math.max(0, position.floor() - 1);
      final int last = math.min(total, position.ceil() + 4);
      final int currentRow = position.round().clamp(0, math.max(0, total - 1));
      for (int i = first; i < last; i++) {
        if (i < 0 || i >= total) {
          continue;
        }
        final (String rowTitle, String artist, String stamp, String kind) = rows[i];
        final bool current = i == currentRow;
        c.row(
          slotY + (i - position) * _rowHeight,
          title: rowTitle,
          artist: artist,
          // 时长缺失时用真实 kind 兜底，不伪造时长。
          stamp: stamp.isNotEmpty ? stamp : _kindLabel(kind),
          action: current ? 'open' : 'music:index:$i',
          number: _pad(i + 1),
          current: current,
        );
      }
    }
    c.endContent();
    c.contentBottom = restoreBottom;
  }

  c.finish();
}

/// 检索结果页（检索框 + 4 个 tab + 结果行）。返回前必须调用 `c.finish()`。
void paintPortraitSearchPage(
  PortraitCanvas c, {
  required String query,
  required List<String> tabLabels, // 如 ['歌曲','歌手','专辑','歌单']
  required int selectedTab,
  required List<(String title, String subtitle, String stamp)> rows,
  required int total,
  required String notice, // 空 = 无提示
  required bool loading,
}) {
  final double h = c.height;

  // 检索是终端页：参考实现整页铺纸色（paperPage → fill({0,0,393,height}, paper)）。
  c.fill(Rect.fromLTWH(0, 0, c.gridWidth, h), c.paper);
  c.header('音乐检索', back: true, backAction: 'close-modal');

  final double top = math.min(126.0, h * .22);
  final double bottom = _pageBottom(c, top);
  double y = top;

  // 检索框：raised 底 + 细边 + 放大镜；字段名固定 `search`，宿主据此贴原生输入条。
  //
  // 这里**只画框**，不画任何文字：键入的正文与空态占位都由 Qt 的输入层自绘
  // （Qt/qml/Overlay.qml:532-612：TextInput 自己显示 text，紧跟的占位 Text
  // `visible: text.length === 0 && !preeditText` 也画占位）。命令流再画一遍就是
  // 双重显示——实机 device7/s1-search.png 里同一个「dx」上下两份、且随输入联动错位。
  final Rect box = Rect.fromLTWH(_left, y, _contentWidth(c), 44);
  c.fill(box, c.raised);
  c.border(box, c.line);
  c.icon('search', 32, y + 13, size: 18, color: c.muted);
  c.field('search', Rect.fromLTWH(58, y, c.gridWidth - 78, 44));
  y += 54;

  // 四等分 tab：居中文字 + 底线；选中项再压一条 amber 指示条。
  final int tabCount = tabLabels.length;
  if (tabCount > 0) {
    final double cell = _contentWidth(c) / tabCount;
    final bool hasSelection = selectedTab >= 0 && selectedTab < tabCount;
    for (int i = 0; i < tabCount; i++) {
      final double x = _left + cell * i;
      final bool selected = hasSelection && i == selectedTab;
      final String label = tabLabels[i];
      final String weight = selected ? 'demibold' : 'regular';
      final double labelWidth = math.max(0.0, cell - 6);
      final double labelX = x + math.max(2.0, (cell - c.measure(label, 12, weight)) / 2);
      c.text(label, labelX, y + 10,
          size: 12, width: labelWidth, weight: weight, color: selected ? c.ink : c.muted);
      c.fill(Rect.fromLTWH(x, y + 32, math.max(0.0, cell - 2), .6), c.line);
      if (selected) {
        c.fill(Rect.fromLTWH(x + 8, y + 32, math.max(0.0, cell - 16), 2), c.amber);
      }
      c.hit(Rect.fromLTWH(x, y, math.max(0.0, cell - 2), 34), 'mobile:search-tab:$i', label);
    }
    y += 42;
  }

  // 结果区上方的提示（例如「已按相关度排序」），只在真的有结果时占一行。
  if (notice.isNotEmpty && rows.isNotEmpty) {
    c.text(notice, _left, y, size: 10, width: _contentWidth(c), color: c.muted);
    y += 16;
  }
  if (y + 22 <= bottom) {
    c.text('检索结果', _left, y, size: 12, width: 200, weight: 'demibold');
    c.rightText('INDEX / ${_pad(total)}', _rightOf(c), y + 2, 8, 'regular', c.muted);
    y += 20;
    c.fill(Rect.fromLTWH(_left, y, _contentWidth(c), .7), c.ink);
  }
  final double listTop = math.min(y + 1, bottom);

  final double clipBottom = math.max(listTop, bottom);
  final double restoreBottom = c.contentBottom;
  c.contentBottom = clipBottom;
  c.beginContent(listTop);
  double cursor = listTop;
  if (loading) {
    // 载入中也保留已有结果，只在顶部补一条状态，避免整块闪空。
    c.text('检索中…', _left, cursor + 8, size: 11, width: _contentWidth(c), color: c.muted);
    cursor += 22;
  }
  if (rows.isEmpty) {
    if (!loading && notice.isNotEmpty) {
      c.text(notice, _left, cursor + 10, size: 11, width: _contentWidth(c), color: c.muted);
    }
  } else {
    final (int first, int last) = c.visibleRows(cursor, _resultRowHeight, rows.length);
    for (int i = first; i < last; i++) {
      if (i < 0 || i >= rows.length) {
        continue;
      }
      final (String rowTitle, String subtitle, String stamp) = rows[i];
      final double rowY = cursor + i * _resultRowHeight;
      c.text(rowTitle, _left, rowY + 9, size: 14, width: _contentWidth(c) - 80, weight: 'demibold');
      if (stamp.isNotEmpty) {
        c.rightText(stamp, _rightOf(c), rowY + 10, 9, 'regular', c.muted);
      }
      c.text(subtitle, _left, rowY + 31, size: 10, width: _contentWidth(c), color: c.muted);
      c.fill(Rect.fromLTWH(_left, rowY + _resultRowHeight - .6, _contentWidth(c), .6), c.line);
      c.hit(Rect.fromLTWH(_left, rowY, _contentWidth(c), _resultRowHeight - 2), 'music:index:$i', rowTitle);
    }
  }
  c.endContent();
  c.contentBottom = restoreBottom;

  c.finish();
}

/// 页面可用底边：宿主的 `contentBottom`（迷你播放条上沿）与真实画布高度取小，
/// 留 6 网格单位安全边；极小视口下保证至少 60 单位的内容高度（不出 NaN / 负高）。
double _pageBottom(PortraitCanvas c, double top) {
  final double limit = math.max(0.0, math.min(c.contentBottom, c.height) - 6);
  return math.max(top + 60, limit);
}

/// 内页遮罩：`ResponsiveHudLayout::arrange` 的纵向阅读渐变
/// （stops 0→.93、.42→.86、.75→.66、1→.95，每 8 单位一条）。
void _pageWash(PortraitCanvas c) {
  const List<double> stops = <double>[0, .42, .75, 1];
  const List<double> alpha = <double>[.93, .86, .66, .95];
  final double h = c.height;
  if (h <= 0) {
    return;
  }
  for (double y = 0; y < h; y += 8) {
    final double fraction = math.min(1.0, y / h);
    double value = alpha.last;
    for (int i = 1; i < stops.length; i++) {
      if (fraction <= stops[i]) {
        final double span = stops[i] - stops[i - 1];
        final double blend = span <= 0 ? 1.0 : (fraction - stops[i - 1]) / span;
        value = alpha[i - 1] + (alpha[i] - alpha[i - 1]) * blend;
        break;
      }
    }
    c.fill(
      Rect.fromLTWH(0, y, c.gridWidth, 8),
      <Object?>[c.paper[0], c.paper[1], c.paper[2], value],
    );
  }
}

/// 两位序号（Qt `MusicData::pad`）。
String _pad(int value) => value.toString().padLeft(2, '0');

/// 行末时长缺失时用真实 kind 兜底；歌曲本身不需要标签，返回空串。
String _kindLabel(String kind) => switch (kind) {
      'playlist' => '歌单',
      'album' => '专辑',
      'artist' => '歌手',
      'collection' => '收藏',
      _ => '',
    };
