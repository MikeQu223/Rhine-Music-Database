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
  c.beginContent(y);

  // tab 行：4 列 × 90 步进，83×44（选中态由 indexTab 自己画指示条）。
  int selectedTab = 0;
  for (int i = 0; i < tabs.length; i += 1) {
    if (tabs[i].selected) selectedTab = i;
    _indexTab(
      c,
      Rect.fromLTWH(20 + (i % 4) * 90, y + (i ~/ 4) * 44, 83, 44),
      tabs[i].label,
      tabs[i].action,
      tabs[i].selected,
    );
  }
  if (tabs.isNotEmpty) {
    c.fill(
      Rect.fromLTWH(
        20 + (selectedTab % 4) * 90,
        y + (selectedTab ~/ 4) * 44 + 39,
        76,
        2,
      ),
      c.amber,
    );
  }
  y += ((tabs.length + 3) ~/ 4) * 44 + 12;

  if (categoryPicker) {
    for (int i = 0; i < categories.length; i += 1) {
      c.chip(
        Rect.fromLTWH(20 + (i % 3) * 120, y + (i ~/ 3) * 44, 113, 36),
        categories[i].label,
        categories[i].action,
        selected: categories[i].selected,
      );
    }
    y += ((categories.length + 2) ~/ 3) * 44;
  } else if (tab == 'playlists' && entries.isNotEmpty) {
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

    // 瓦片：2 列，169×144 封面 + 标题/艺人，命中 169×186 并被内容区底界裁掉。
    final double contentBottom = c.contentBottom;
    for (final PortraitDiscoverEntry tile in entries.skip(1)) {
      final int i = tile.index;
      final int col = (i - 1) % 2;
      final int row = (i - 1) ~/ 2;
      final double x = 20 + col * 184;
      final double top = y + row * 196;
      c.fill(Rect.fromLTWH(x, top, 169, 144), c.surface);
      if (tile.image.isNotEmpty) {
        c.image(tile.image, Rect.fromLTWH(x, top, 144, 144));
      }
      c.text(_pad(i + 1), x + 150, top + 8, size: 8, width: 19, color: c.muted);
      c.text(tile.title, x, top + 153, size: 12, width: 104, weight: 'demibold');
      c.text(tile.artist, x, top + 173, size: 9, width: 169, color: c.muted);
      final Rect tileRect = Rect.fromLTWH(x, top, 169, 186);
      final Rect? visible = _intersect(tileRect, Rect.fromLTWH(20, 130, w - 40, contentBottom - 130));
      if (visible != null && visible.height >= 8) {
        c.hit(visible, '$portraitDiscoverItemPrefix$i', tile.title);
        if (tile.isPlaylist) {
          c.text('▶ 全部', x + 114, top + 154, size: 9, width: 55);
          c.hit(
            Rect.fromLTWH(x + 110, top + 144, 59, 42),
            '$portraitPlayDiscoverPrefix$i',
            '播放全部',
          );
        }
      }
    }
    y += (entries.length ~/ 2) * 196;
  } else {
    for (int i = 0; i < tools.length; i += 1) {
      c.chip(
        Rect.fromLTWH(20 + (i % 2) * 181, y + (i ~/ 2) * 44, 172, 36),
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
