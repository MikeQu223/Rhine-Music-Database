/// 竖屏（compact）「我的歌单」整页：命令流排版，不建 widget。
///
/// 这是资料库 lane 2 的**整页视图**。真源：
/// - `Qt/src/MusicSiren.cpp:251-335`：lane 2 的行就是 `collections->playlists()`
///   （`lists[2]`），一次灌入、`hasMore[2]` 恒 false；空集合的 status 是
///   `"暂无本地歌单，可点击创建歌单"`。
/// - `Qt/src/LocalCollections.cpp:137-157`：每行的投影是
///   `{title, trackCount, description:"本地歌单 · 仅保存在本机", creatorID, localCollection}`。
/// - `Qt/src/ResponsiveHudPages.cpp:917-941`：lane≥2 在 Qt 里走**封面网格**分支，
///   每个格子带 `▶ 全部`（动作 `mobile:play-collection:<percent-encoded JSON>`）和
///   格子命中 `music:result:<lane>:<index>`。
/// - `Qt/src/ResponsiveHudPages.cpp:942-...` 的通用分支：检索框 + 四个 indexTab +
///   `terminalSection(y, "01", "音乐档案", "INDEX / N")` 之后才是行。
///
/// 本卡要求这一页是「歌单行 + 计数 + 空态」，所以取 Qt 通用分支的**行式骨架**
/// （`terminalSection` + `c.row`）而不是封面网格：行标题 = 歌单名、副标题 = Qt 的
/// `description` 原文、行末戳 = `<trackCount> 首`（LocalCollections 只给计数，
/// 不给时长，戳位不编时间）。封面网格与 `▶ 全部` 的组合动作留给后续卡片，
/// 本文件不臆造那串 `mobile:play-collection:` 载荷。
///
/// 页宽一律读 `c.gridWidth`（设计稿 353 = 393 - 40），不写死 393。
library;

import 'dart:math' as math;
import 'dart:ui' show Rect;

import 'portrait_canvas.dart';

/// 一行歌单：id（留给后续「播放全部/打开歌单」接线）、标题、曲目数。
class PortraitPlaylistRow {
  const PortraitPlaylistRow({
    required this.id,
    required this.title,
    required this.trackCount,
  });

  /// 歌单 id（`BasicLocalPlaylist.id`；Qt 是 UUID，无花括号）。
  final String id;

  /// 歌单名（`BasicLocalPlaylist.title`，Qt 的 `name`）。空串时按
  /// `lib/basic/basic_models.dart` 的既有口径显示「未命名歌单」。
  final String title;

  /// 歌单内曲目数（Qt `playlistItem` 的 `trackCount`，LocalCollections.cpp:143）。
  final int trackCount;
}

/// 行距（Qt 每行 68 网格单位，ResponsiveHudPages.cpp:911）。
const double portraitPlaylistsRowStride = 68;

/// 正文左右留白（Qt 的 20 / 373 对）。
const double _gutter = 20;

/// 「+ 创建歌单」按钮的动作串（Qt ResponsiveHudPages.cpp:889 原文）。
const String portraitCreatePlaylistAction = 'music:create-playlist';

/// 返回动作：Qt 把 saved 页的 `close-modal` 改写成 `mobile:mine`
/// （ResponsiveHudLayout.cpp:181-189）。
const String _savedBackAction = 'mobile:mine';

/// 画「我的歌单」竖屏页。
///
/// [rows] 是这一页要列的歌单（顺序由调用方给，Qt 是 createdAt 降序 / 新建在最前）；
/// [selectedIndex] 是当前条目在 [rows] 里的下标（越界 = 无高亮）；
/// [loading] 为真且 [rows] 为空时，空态标题换成读取中的诚实文案；
/// [notice] 是空态/状态文案（Qt 这里放 `sourceMessage(lane)`），空串表示没有；
/// [canCreate] 为真时画「+ 创建歌单」——Qt 竖屏把入口放在资料库**目录页**
/// （ResponsiveHudPages.cpp:888-891），列表页要它得由宿主显式打开。
void paintPortraitPlaylistsPage(
  PortraitCanvas c, {
  required List<PortraitPlaylistRow> rows,
  required int selectedIndex,
  required bool loading,
  required String notice,
  bool canCreate = false,
}) {
  final double width = c.gridWidth - 2 * _gutter;
  final double height = c.height;
  // 整页纸色（Qt arrange()：非 home 非 song 页先铺满 paper，ResponsiveHudLayout.cpp:96-98）。
  c.fill(Rect.fromLTWH(0, 0, c.gridWidth, height), c.paper);
  c.header('我的歌单', back: true, backAction: _savedBackAction);

  final double top = _contentTop(c);
  final double bottom = _pageBottom(c, top);

  double y = top;
  // 终端式小标题（Qt terminalSection：03 黑底编号块 + 标题 + 右对齐 INDEX / N）。
  _terminalSection(c, y, '01', '音乐档案', 'INDEX / ${_pad(rows.length)}', width);
  y += 29;

  if (canCreate && y + 44 <= bottom) {
    c.button(
      Rect.fromLTWH(_gutter, y, width, 44),
      '+ 创建歌单',
      portraitCreatePlaylistAction,
      primary: true,
    );
    y += 56;
  }

  final double listTop = math.min(y, bottom);
  if (bottom - listTop < 24) {
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
        c.visibleRows(listTop, portraitPlaylistsRowStride, rows.length);
    for (int index = first; index < last; index++) {
      final PortraitPlaylistRow row = rows[index];
      c.row(
        listTop + index * portraitPlaylistsRowStride,
        title: row.title.isEmpty ? '未命名歌单' : row.title,
        // Qt 的 description 原文（LocalCollections.cpp:144）：不编别的副标题。
        artist: '本地歌单 · 仅保存在本机',
        stamp: '${row.trackCount} 首',
        // Qt saved 页的行动作（NativeHud.cpp:533-538），lane 2。
        action: 'music:result:2:$index',
        number: _pad(index + 1),
        current: index == selectedIndex,
      );
    }
  }
  c.endContent();
  c.contentBottom = previousBottom;
  c.finish();
}

/// Qt `ResponsiveHudCanvas::terminalSection`（ResponsiveHudPages.cpp:28-35）：
/// 23×18 的墨块 + 居中编号 + 标题 + 右缘说明。
void _terminalSection(
  PortraitCanvas c,
  double y,
  String number,
  String title,
  String caption,
  double width,
) {
  c.fill(Rect.fromLTWH(_gutter, y, 23, 18), c.ink);
  c.centered(number, 31.5, y + 9, 8, 'regular', c.paper);
  c.text(title, 51, y + 2, size: 13, width: 180, weight: 'demibold');
  c.rightText(caption, _gutter + width, y + 5, 7, 'regular', c.muted);
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
  c.icon('folder', _gutter, top + 30, size: 24, color: c.muted);
  c.text(
    loading ? '正在读取…' : '暂无本地歌单',
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

/// 两位序号（Qt `MusicData::pad`）。
String _pad(int value) => value.toString().padLeft(2, '0');
