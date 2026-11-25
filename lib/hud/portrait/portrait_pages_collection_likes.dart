/// 竖屏（compact）「喜欢的歌曲」整页：命令流排版，不建 widget。
///
/// 这是资料库 lane 1 的**整页视图**，真源是
/// `Qt/src/ResponsiveHudPages.cpp:896-915` 的 `library()` 分支（`musicCollection == 1`）：
/// ```
/// c.text("PERSONAL ARCHIVE / " + N + " TRACKS", 20, y, 9, 353, "regular", muted); y += 25;
/// c.border({20, y, 353, 150}, c.line);
/// c.text("COLLECTION / 收藏资料库", 32, y + 13, 8, 329, "regular", muted);
/// c.text("喜欢的歌曲", 32, y + 108, 24, 329, "demibold");                       y += 167;
/// c.button({20, y, 172, 44}, "▶ 播放全部", "mobile:play-liked", true);
/// c.button({201, y, 172, 44}, "查看队列", "player:open");                       y += 63;
/// for (…) c.row(y + row * 68., title, artist, time(value), entry["action"], pad(row + 1));
/// ```
/// 逐条对应关系：
/// - 页宽：设计稿的 353 = 393 - 左右各 20，这里一律读 `c.gridWidth - 40`；
///   两个按钮的 172/9/172 也按页宽折半，不写死 393。
/// - 内容起点：Qt `y = 158 - m_scroll`（saved 页无滚动时即 158），小视口按
///   `height * .22` 收窄，避免整块跑出屏幕。
/// - 返回：Qt `arrange()` 在 modal=="saved" 且非概览时把 `close-modal` 命中改写成
///   `mobile:mine`（ResponsiveHudLayout.cpp:181-189），这里是同一动作串。
/// - 行命中：Qt saved 页的行 action 来自 `NativeHud.cpp:533-538` 的
///   `"music:result:" + lane + ":" + row.index`，lane 1 → `music:result:1:<i>`。
///   本页按 Qt 分支原样**不区分当前行**，只把 [paintPortraitLikesPage] 收到的
///   [selectedIndex] 画成高亮（Qt 该分支不传 `current`，视觉差异仅此一处）。
/// - 空态：Qt 用 `fill({20,y+8,…})` 细线 + 24 图标 + 16 demibold 标题 +
///   11 muted 段落的空态块；图标这里用 lane 1 自己的 `heart`（Qt 概览页 lane 1 的
///   indexRow 图标就是 `heart`），标题文案取自 MusicSiren.cpp 的 `暂无喜欢的歌曲`。
///
/// 本文件只排版：不持有选中/加载状态，也不发请求。
library;

import 'dart:math' as math;
import 'dart:ui' show Rect;

import 'portrait_canvas.dart';

/// 一行歌曲：标题、艺人、行末戳（时长；缺省给空串，不编造）。
typedef PortraitLikesRow = (String title, String artist, String stamp);

/// 行距（Qt 每行 68 网格单位，ResponsiveHudPages.cpp:911）。
const double portraitLikesRowStride = 68;

/// 正文左右留白（Qt 的 20 / 373 对）。
const double _gutter = 20;

/// 「播放全部」按钮的动作串（Qt ResponsiveHudPages.cpp:904 原文）。
const String portraitPlayLikedAction = 'mobile:play-liked';

/// 「查看队列」按钮的动作串（Qt ResponsiveHudPages.cpp:905 原文）。
const String portraitOpenQueueAction = 'player:open';

/// 返回动作：Qt 把 saved 页的 `close-modal` 改写成 `mobile:mine`
/// （ResponsiveHudLayout.cpp:181-189）。
const String _savedBackAction = 'mobile:mine';

/// 画「喜欢的歌曲」竖屏页。
///
/// [rows] 是这一页要列的歌曲（最多等于 `totals[1]`，分页由调用方决定）；
/// [selectedIndex] 是当前条目在 [rows] 里的下标（越界 = 无高亮）；
/// [loading] 为真且 [rows] 为空时，空态标题换成读取中的诚实文案；
/// [notice] 是空态/状态文案（Qt 空态块的第二行就是 `s["status"]`），空串表示没有。
void paintPortraitLikesPage(
  PortraitCanvas c, {
  required List<PortraitLikesRow> rows,
  required int selectedIndex,
  required bool loading,
  required String notice,
  double scroll = 0,
}) {
  final double width = c.gridWidth - 2 * _gutter;
  final double height = c.height;
  // 整页纸色（Qt arrange()：非 home 非 song 页先铺满 paper，ResponsiveHudLayout.cpp:96-98）。
  c.fill(Rect.fromLTWH(0, 0, c.gridWidth, height), c.paper);
  // 页头：标题取自 collectionTitle（Qt 默认「我的音乐」，lane 1 即本页标题），
  // 返回命中走 mobile:mine。
  c.header('喜欢的歌曲', back: true, backAction: _savedBackAction);

  // Qt `y = (search ? 130 : 158) - scroll`；小视口按比例收。
  final double top = _contentTop(c);
  // 收藏列可能有上百首（真机 100 首），必须能滚：卡片与按钮跟着滚动量整体上移，
  // 列表行自己再让出同样的距离。
  final double headTop = top - scroll;
  final double bottom = _pageBottom(c, top);

  double y = headTop;
  c.text(
    'PERSONAL ARCHIVE / ${rows.length} TRACKS',
    _gutter,
    y,
    size: 9,
    width: width,
    color: c.muted,
  );
  y += 25;

  // 收藏资料库卡片：150 高、1px 边框、两条文案（Qt y+13 / y+108）。
  final Rect card = Rect.fromLTWH(_gutter, y, width, 150);
  c.border(card, c.line);
  c.text('COLLECTION / 收藏资料库', 32, y + 13, size: 8, width: width - 12, color: c.muted);
  c.text('喜欢的歌曲', 32, y + 108, size: 24, width: width - 12, weight: 'demibold');
  y += 167;

  // 两个 44 高按钮：172 / 9 / 172 在 393 页宽下铺满 353，这里按页宽折半。
  final double buttonWidth = (width - 9) / 2;
  if (y + 44 <= bottom) {
    c.button(
      Rect.fromLTWH(_gutter, y, buttonWidth, 44),
      '▶ 播放全部',
      portraitPlayLikedAction,
      primary: true,
    );
    c.button(
      Rect.fromLTWH(_gutter + buttonWidth + 9, y, buttonWidth, 44),
      '查看队列',
      portraitOpenQueueAction,
    );
    y += 63;
  } else {
    // 视口太矮：不硬塞按钮，直接让列表吃掉剩余高度。
    y = math.min(y, bottom);
  }

  final double listTop = math.min(y, bottom);
  if (bottom - listTop < 24) {
    // 连一行的位置都没有：不留半行的假象。
    c.finish();
    return;
  }

  final double previousBottom = c.contentBottom;
  c.contentBottom = bottom;
  c.beginContent(listTop);
  if (rows.isEmpty) {
    _paintEmpty(c, top: listTop, width: width, loading: loading, notice: notice);
  } else {
    final (int first, int last) =
        c.visibleRows(listTop, portraitLikesRowStride, rows.length);
    for (int index = first; index < last; index++) {
      final PortraitLikesRow row = rows[index];
      c.row(
        listTop + index * portraitLikesRowStride,
        title: row.$1,
        artist: row.$2,
        stamp: row.$3,
        action: 'music:result:1:$index',
        number: _pad(index + 1),
        current: index == selectedIndex,
      );
    }
  }
  c.endContent();
  c.contentBottom = previousBottom;
  c.finish();
}

/// 空态块（Qt `library()` 的空分支几何：细线 + 图标 + 16 demibold 标题 + 11 段落）。
void _paintEmpty(
  PortraitCanvas c, {
  required double top,
  required double width,
  required bool loading,
  required String notice,
}) {
  c.fill(Rect.fromLTWH(_gutter, top + 8, width, .6), c.line);
  c.icon('heart', _gutter, top + 30, size: 24, color: c.muted);
  c.text(
    loading ? '正在读取…' : '暂无喜欢的歌曲',
    60,
    top + 30,
    size: 16,
    width: width - 40,
    weight: 'demibold',
  );
  if (notice.isNotEmpty) {
    c.paragraph(notice, 60, top + 60, size: 11, width: width - 40, color: c.muted);
  }
}

/// 内容起点：Qt 是 158（saved 页），极小视口按高度比例收窄。
double _contentTop(PortraitCanvas c) => math.min(158, math.max(0, c.height * .22));

/// 页面可用底边：与 `contentBottom` / 真实高度取小，留 6 单位安全边。
double _pageBottom(PortraitCanvas c, double top) {
  final double limit = math.max(0.0, math.min(c.contentBottom, c.height) - 6);
  return math.max(top + 60, limit);
}

/// 两位序号（Qt `MusicData::pad`，ResponsiveHudPages.cpp:912）。
String _pad(int value) => value.toString().padLeft(2, '0');
