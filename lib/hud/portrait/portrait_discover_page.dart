/// 竖屏「发现音乐」页（Qt compact `ResponsiveHudLayout::discover`）。
///
/// 真源：`Qt/src/ResponsiveHudPages.cpp:376-470`。本页与其它竖屏页同口径，用
/// `c.gridWidth` 相对推算宽度（Qt 用 393 设计稿常量），DPI 适配后不会挤成窄柱。
///
/// 三块内容按 Qt 的优先级择一（不是叠加）：
///   1. `categoryPicker`：分类 chip 网格（3 列，113×36，步进 44）；
///   2. `tab == 'playlists'` 且有内容：头图卡（116 高）+ `01 音乐档案` + 2 列瓦片；
///   3. 其它：工具 chip（2 列，172×36）+ 行列表（68 步进）。
/// 末尾按 `more` 给「加载更多 ↓」；`loadedCount == 0 && !categoryPicker` 时把
/// `status` 段落当主体（Qt 用 `paragraph(...) + 20` 覆盖 y）。
library;

import 'dart:math' as math;
import 'dart:ui' show Rect;

import 'portrait_canvas.dart';
import 'portrait_layout.dart';

/// 发现页内容起点（Qt `y = 130 - m_scroll`，`modal == "discover"` 是终端页）。
const double portraitDiscoverContentTop = 130;

/// 动作串（与 Qt 常量一致，勿新造）。
const String portraitDiscoverItemPrefix = 'discover:item:';
const String portraitDiscoverMoreAction = 'discover:more';
const String portraitDiscoverTabPrefix = 'discover:tab:';
const String portraitPlayDiscoverPrefix = 'mobile:play-discover:';

/// 单卡最大宽度（网格），竖屏上限 120：586 网格 ⇒ 4 列，393 稿 2 列，上限 6 列。
/// 横屏不受影响：走 Qt 桌面弹层的 `DiscoverCard`（固定五列）。
const double portraitDiscoverTileMaxWidth = 120;

/// 发现页瓦片列数：按页宽动态，2..6 列。
int portraitDiscoverColumnsForWidth(double gridWidth) {
  final double usable = math.max(1, gridWidth - 40);
  return (usable / portraitDiscoverTileMaxWidth).floor().clamp(2, 6);
}

/// 一行发现条目（Qt `DiscoverEntry` 的竖屏投影）。
class PortraitDiscoverEntry {
  const PortraitDiscoverEntry({
    required this.index,
    required this.title,
    required this.artist,
    this.kind = 'song',
    this.image = '',
  });

  final int index;
  final String title;
  final String artist;

  /// `song` / `playlist` / `album` / `artist`；歌单额外给「▶ 全部」。
  final String kind;
  final String image;

  bool get isPlaylist => kind == 'playlist';
}

/// tab / 分类 / 工具 chip 的数据。
class PortraitDiscoverChip {
  const PortraitDiscoverChip({
    required this.label,
    required this.action,
    this.selected = false,
  });

  final String label;
  final String action;
  final bool selected;
}

/// 画「发现音乐」页，返回内容总高（供宿主算滚动上限）。
double paintPortraitDiscoverPage(
  PortraitCanvas c, {
  required List<PortraitDiscoverChip> tabs,
  required String tab,
  List<PortraitDiscoverChip> tools = const <PortraitDiscoverChip>[],
  List<PortraitDiscoverChip> categories = const <PortraitDiscoverChip>[],
  bool categoryPicker = false,
  List<PortraitDiscoverEntry> entries = const <PortraitDiscoverEntry>[],
  String status = '',
  bool more = false,
  bool loadingMore = false,
  double scroll = 0,
}) {
  final double w = c.gridWidth;
  c.fill(Rect.fromLTWH(0, 0, w, math.max(0, c.height)), c.paper);
  paintPortraitTerminalHeader(
    c,
    title: '发现音乐',
    code: '01',
    identifier: 'DISCOVER / 音乐观察',
  );

  double y = portraitDiscoverContentTop - scroll;
  // 裁剪区顶端固定在 130（Qt `ResponsiveHudLayout.cpp:227` 的 `c.beginContent(130)`）：
  // 传 `y` 会把裁剪线跟着滚动上移，列表上滑后内容穿透页头（用户报「标题栏没有背景」）。
  c.beginContent(portraitDiscoverContentTop);

  // tab 行：4 列，步进按页宽算（Qt 固定 90/83 是 393 设计稿口径，DPI 适配后
  // 页宽变宽，照抄固定值会挤在左侧一窄条，和检索页/设置页的观感不一致）。
  final double tabStep = (w - 40) / 4;
  final double tabWidth = tabStep - 7;
  int selectedTab = 0;
  for (int i = 0; i < tabs.length; i += 1) {
    if (tabs[i].selected) selectedTab = i;
    _indexTab(
      c,
      Rect.fromLTWH(20 + (i % 4) * tabStep, y + (i ~/ 4) * 44, tabWidth, 44),
      tabs[i].label,
      tabs[i].action,
      tabs[i].selected,
    );
  }
  if (tabs.isNotEmpty) {
    c.fill(
      Rect.fromLTWH(
        20 + (selectedTab % 4) * tabStep,
        y + (selectedTab ~/ 4) * 44 + 39,
        tabWidth - 7,
        2,
      ),
      c.amber,
    );
  }
  y += ((tabs.length + 3) ~/ 4) * 44 + 12;

  if (categoryPicker) {
    final double chipStep = (w - 40) / 3;
    for (int i = 0; i < categories.length; i += 1) {
      c.chip(
        Rect.fromLTWH(20 + (i % 3) * chipStep, y + (i ~/ 3) * 44, chipStep - 7, 36),
        categories[i].label,
        categories[i].action,
        selected: categories[i].selected,
      );
    }
    y += ((categories.length + 2) ~/ 3) * 44;
  }
  // 分类页的 chip 行只是过滤轴，下面照样要把当前分类的歌单画出来（Qt 的
  // `discover()` 里 chip 与瓦片是同一段流程，不是二选一）。
  if (entries.isNotEmpty && (tab == 'playlists' || categoryPicker)) {
    final PortraitDiscoverEntry hero = entries.first;
    c.fill(Rect.fromLTWH(20, y, w - 40, 116), c.surface);
    c.fill(Rect.fromLTWH(20, y, 2, 116), c.amber);
    c.text('FEATURED / 今日档案', 33, y + 12, size: 8, width: w - 168, color: c.muted);
    c.paragraph(hero.title, 33, y + 34, size: 18, width: math.max(80, w * .41),
        weight: 'demibold', maximumLines: 2);
    c.text(hero.artist, 33, y + 92, size: 10, width: w - 168, color: c.muted);
    if (hero.image.isNotEmpty) {
      c.image(hero.image, Rect.fromLTWH(w - 134, y + 16, 80, 80));
    }
    c.hit(
      Rect.fromLTWH(20, y, w - 40, 116),
      '$portraitDiscoverItemPrefix${hero.index}',
      hero.title,
    );
    if (hero.isPlaylist) {
      c.text('▶ 全部', w - 208, y + 45, size: 10, width: 62);
      c.hit(
        Rect.fromLTWH(w - 214, y + 30, 70, 44),
        '$portraitPlayDiscoverPrefix${hero.index}',
        '播放全部',
      );
    }
    y += 132;
    c.section(y, '音乐档案', 'SELECTED / ${entries.length}');
    y += 25;

    // 瓦片列数按页宽动态。Qt 的稿子按 393 页宽算（卡 169×144、封面 144、编号在右）；
    // 这里保留同一比例，只把宽度换成格宽，写死 144 会让封面只占格子一半。
    final double contentBottom = c.contentBottom;
    final int columns = portraitDiscoverColumnsForWidth(w);
    final double tileStep = (w - 40) / columns;
    final double cardWidth = tileStep - 15;
    final double coverSize = math.max(72, cardWidth - 25);
    final double tileStride = coverSize + 52;
    for (final PortraitDiscoverEntry tile in entries.skip(1)) {
      final int i = tile.index;
      final int col = (i - 1) % columns;
      final int row = (i - 1) ~/ columns;
      final double x = 20 + col * tileStep;
      final double top = y + row * tileStride;
      c.fill(Rect.fromLTWH(x, top, cardWidth, coverSize), c.surface);
      if (tile.image.isNotEmpty) {
        c.image(tile.image, Rect.fromLTWH(x, top, coverSize, coverSize));
      }
      c.text(_pad(i + 1), x + coverSize + 6, top + 8, size: 8, width: 19, color: c.muted);
      // 「▶ 全部」贴**整张卡片的右缘**（不是封面右缘）：原先把按钮压在封面宽度以内，
      // 标题可用宽只有 `coverSize - 40`，长标题一律截成「二次元小…」；卡片右侧那
      // 25 宽的编号竖条本来就是空的，把按钮挪过去的同一行既对齐又给文字让位。
      final double playWidth = c.measure('▶ 全部', 9);
      final double playRight = x + cardWidth;
      final double playLeft = playRight - playWidth;
      final double titleLimit = math.max(48, playLeft - 6 - x);
      c.text(tile.title, x, top + coverSize + 9, size: 12,
          width: titleLimit, weight: 'demibold');
      c.text(tile.artist, x, top + coverSize + 29, size: 9, width: cardWidth, color: c.muted);
      final Rect tileRect = Rect.fromLTWH(x, top, cardWidth, coverSize + 42);
      final Rect? visible = _intersect(tileRect, Rect.fromLTWH(20, 130, w - 40, contentBottom - 130));
      if (visible != null && visible.height >= 8) {
        c.hit(visible, '$portraitDiscoverItemPrefix$i', tile.title);
        if (tile.isPlaylist) {
          c.text('▶ 全部', playLeft, top + coverSize + 10, size: 9, width: playWidth + 2);
          c.hit(
            Rect.fromLTWH(playLeft - 4, top + coverSize, playWidth + 4, 42),
            '$portraitPlayDiscoverPrefix$i',
            '播放全部',
          );
        }
      }
    }
    final int tileRows =
        entries.length <= 1 ? 0 : ((entries.length - 1 + columns - 1) ~/ columns);
    y += tileRows * tileStride;
  } else {
    final double toolStep = (w - 40) / 2;
    for (int i = 0; i < tools.length; i += 1) {
      c.chip(
        Rect.fromLTWH(20 + (i % 2) * toolStep, y + (i ~/ 2) * 44, toolStep - 9, 36),
        tools[i].label,
        tools[i].action,
        selected: tools[i].selected,
      );
    }
    if (tools.isNotEmpty) y += ((tools.length + 1) ~/ 2) * 44 + 12;
    for (final PortraitDiscoverEntry entry in entries) {
      c.row(
        y + entry.index * 68,
        title: entry.title,
        artist: entry.artist,
        stamp: '',
        action: '$portraitDiscoverItemPrefix${entry.index}',
        number: _pad(entry.index + 1),
        remove: entry.isPlaylist ? '$portraitPlayDiscoverPrefix${entry.index}' : '',
        image: entry.image,
        hasImage: entry.image.isNotEmpty,
      );
    }
    y += entries.length * 68;
  }

  if (entries.isEmpty && !categoryPicker && status.isNotEmpty) {
    y = c.paragraph(status, 20, y + 15, size: 14, width: w - 40, color: c.muted) + 20;
  }
  if (more) {
    c.button(
      Rect.fromLTWH(20, y, w - 40, 44),
      loadingMore ? '载入中…' : '加载更多 ↓',
      portraitDiscoverMoreAction,
    );
    y += 56;
  }

  c.endContent();
  c.finish();
  return math.max(y + scroll + 20, c.contentBottom + 20);
}

/// 两个矩形的交集（无交集返回 null）；`dart:ui` 没有现成的 intersection 方法。
Rect? _intersect(Rect a, Rect b) {
  final double left = math.max(a.left, b.left);
  final double top = math.max(a.top, b.top);
  final double right = math.min(a.right, b.right);
  final double bottom = math.min(a.bottom, b.bottom);
  if (right <= left || bottom <= top) return null;
  return Rect.fromLTRB(left, top, right, bottom);
}

String _pad(int value) => value.toString().padLeft(2, '0');

/// Qt `indexTab`（ResponsiveHudCanvas.cpp:17-23）：文字 x = rect.x + 7、y = rect.y + 12、
/// 宽 = rect.width - 14；底部细线 `{rect.x, rect.bottom - 5, rect.width - 7, .6}`；命中整格。
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
  c.fill(Rect.fromLTWH(rect.left, rect.bottom - 5, rect.width - 7, .6), c.line);
  c.hit(rect, action, label);
}
