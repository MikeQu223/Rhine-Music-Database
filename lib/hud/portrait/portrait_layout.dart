/// 竖屏（compact）主页：`Qt/src/ResponsiveHudPages.cpp:46-172` 的 archive 页，
/// 加上 `Qt/src/ResponsiveHudLayout.cpp:329-420` 的迷你播放条与底部导航。
///
/// 只负责「把一份输入排版成命令流」：滚动位置、吸附、手势都由宿主
/// （`BasicHudSurface`）持有，这里收到的 `listPosition` 已经是连续条目位置
/// （= 对齐到第二行的那个窗口位置），与横屏 ruler 的 position 同一语义。
library;

import 'dart:math' as math;
import 'dart:ui' show Rect;

import '../protocol/hud_hit.dart';
import 'portrait_canvas.dart';

/// 393 网格：舞台宽 1080 时的单位换算（Qt `m_unit = stageWidth / 393`）。
const double portraitDesignWidth = 393;

/// 舞台宽 1080 → unit = 2.748…；unit 由调用方按真实舞台宽算，这里只给设计稿宽。
double portraitUnit(double stageWidth) => stageWidth / portraitDesignWidth;

/// 393 网格里的可视高度（Qt `m_height = 1080 / m_unit`）。
double portraitGridHeight(double stageHeight, double unit) => stageHeight / unit;

/// 行高、手势内缩、播放条高度（Qt ResponsiveHudLayout 的常量）。
const double portraitRowHeight = 48;
const double portraitGestureInset = 34;

/// 底栏四项。
enum PortraitNav { archive, discover, search, settings }

extension PortraitNavLabel on PortraitNav {
  String get title => switch (this) {
        PortraitNav.archive => '资料库',
        PortraitNav.discover => '发现',
        PortraitNav.search => '搜索',
        PortraitNav.settings => '设置',
      };

  String get code => switch (this) {
        PortraitNav.archive => 'ARCHIVE',
        PortraitNav.discover => 'DISCOVER',
        PortraitNav.search => 'SEARCH',
        PortraitNav.settings => 'SETTINGS',
      };

  String get action => switch (this) {
        PortraitNav.archive => 'mobile:nav:archive',
        PortraitNav.discover => 'mobile:nav:discover',
        PortraitNav.search => 'search',
        PortraitNav.settings => 'settings',
      };
}

/// 一个来源 tab（Qt 的五列，标签取真实列名）。
class PortraitTab {
  const PortraitTab({required this.label, required this.lane});

  final String label;
  final int lane;
}

/// 列表行：只有标题与 kind（封面/时长在竖屏列表里不画，与参考图一致）。
class PortraitRow {
  const PortraitRow({required this.title, required this.kind});

  final String title;
  final String kind;

  bool get isSong => kind == 'song';
}

/// 主页归档输入。
class PortraitArchive {
  const PortraitArchive({
    required this.tabs,
    required this.selectedLane,
    required this.title,
    required this.rows,
    required this.index,
    this.directory = false,
    this.canPlayAll = true,
    this.emptyNotice = '',
  });

  final List<PortraitTab> tabs;

  /// 当前列（真实 lane 号，不是 tab 下标）。
  final int selectedLane;

  /// 标题：目录标题或列名。
  final String title;

  final List<PortraitRow> rows;

  /// 选中行（当前条目），用于高亮与 `open` 命中。
  final int index;

  final bool directory;
  final bool canPlayAll;

  /// 空列/未接入时的诚实文案（空串 = 无）。
  final String emptyNotice;

  int get total => rows.length;

  int get selectedTab {
    final int at = tabs.indexWhere((PortraitTab tab) => tab.lane == selectedLane);
    return at < 0 ? 0 : at;
  }
}

/// 播放条输入（只认真实在播的曲目）。
class PortraitPlayer {
  const PortraitPlayer({
    this.title = '',
    this.artist = '',
    this.cover = '',
    this.hasTrack = false,
    this.playing = false,
    this.positionMs = 0,
    this.durationMs = 0,
  });

  final String title;
  final String artist;
  final String cover;
  final bool hasTrack;
  final bool playing;
  final double positionMs;
  final double durationMs;

  double get fraction =>
      durationMs > 0 ? (positionMs / durationMs).clamp(0.0, 1.0) : 0.0;
}

/// 一帧竖屏命令流。命中已在舞台单位（画布发射时乘过 unit）。
class PortraitFrame {
  PortraitFrame({
    required this.commands,
    required this.hits,
    required this.fields,
    required this.listTop,
  });

  final List<List<Object?>> commands;
  final List<HudHit> hits;
  final Map<String, Rect> fields;
  final double listTop;
}

/// 列表带顶（Qt `archiveListTop()`）：
/// `max(h*.5, h - 34 - 110 - 48*4)`。
double portraitListTop(double height) => math.max(
      height * .5,
      height - portraitGestureInset - 110 - portraitRowHeight * 4,
    );

/// 画一帧竖屏主页（含播放条与底栏）。
PortraitFrame paintPortraitHome(
  PortraitCanvas canvas, {
  required PortraitArchive archive,
  required PortraitPlayer player,
  required PortraitNav nav,
  double? listPosition,
}) {
  final double h = canvas.height;
  final double listTop = portraitListTop(h);
  final int total = archive.total;
  final double position =
      (listPosition ?? archive.index.toDouble()).clamp(0.0, math.max(0.0, total - 1.0));

  canvas.contentBottom = listTop + portraitRowHeight * 4;

  _brand(canvas);
  _tabs(canvas, archive);
  _title(canvas, archive, listTop);
  _list(canvas, archive, listTop, position, total);
  _playerAndNav(canvas, player: player, nav: nav, top: canvas.contentBottom);
  canvas.finish();

  return PortraitFrame(
    commands: canvas.commands,
    hits: canvas.hits,
    fields: canvas.fields,
    listTop: listTop,
  );
}

void _brand(PortraitCanvas c) {
  c.text('RHINE LAB', 23, 22, size: 17, width: 200, weight: 'bold');
  c.text('MUSIC ARCHIVE / 音乐资料库', 23, 43, size: 7, width: 240, color: c.muted);
  c.rightText('AUDIO TERMINAL / RL–004', 370, 29, 7, 'regular', c.muted);
  c.fill(Rect.fromLTWH(23, 58, 347, .6), c.line);
}

void _tabs(PortraitCanvas c, PortraitArchive archive) {
  final List<PortraitTab> tabs = archive.tabs;
  if (tabs.isEmpty) {
    return;
  }
  final double tabWidth = 347 / tabs.length;
  for (int index = 0; index < tabs.length; index++) {
    final double x = 23 + tabWidth * index;
    final bool selected = index == archive.selectedTab;
    c.text(tabs[index].label, x + 2, 76,
        size: 10, width: tabWidth - 6, color: selected ? c.ink : c.muted);
    c.fill(Rect.fromLTWH(x, 98, tabWidth - 8, .6), c.line);
    if (selected) {
      c.fill(Rect.fromLTWH(x, 98, tabWidth - 8, 2), c.amber);
    }
    c.hit(Rect.fromLTWH(x, 68, tabWidth - 6, 34), 'mobile:lane:${tabs[index].lane}',
        tabs[index].label);
  }
}

void _title(PortraitCanvas c, PortraitArchive archive, double listTop) {
  c.text(archive.title, 23, 123,
      size: 23, width: archive.canPlayAll ? 250 : 345, weight: 'bold');
  if (archive.canPlayAll && archive.total > 0) {
    c.icon('play', 288, 126, size: 15);
    c.text('播放全部', 309, 127, size: 10, width: 74);
    c.hit(Rect.fromLTWH(280, 114, 94, 44), 'music:play-loaded', '播放全部');
  }
  c.text('上下滑动浏览 / TRACK INDEX', 23, listTop - 18, size: 8, width: 240, color: c.muted);
  final String counter = archive.total == 0
      ? '00 / 00'
      : '${_pad(archive.index + 1)} / ${_pad(archive.total)}';
  c.rightText(counter, 370, listTop - 18, 8, 'regular', c.ink);
  c.fill(Rect.fromLTWH(23, listTop - 4, 347, .7), c.ink);
}

void _list(
  PortraitCanvas c,
  PortraitArchive archive,
  double listTop,
  double position,
  int total,
) {
  final double bottom = listTop + portraitRowHeight * 4;
  // 3D 场景的原生矩形在竖屏只到 1080 舞台单位（网格 393），正好落在列表带中间：
  // 不在列表带铺纸色就会看到场景下沿一条硬切边（v101 实机截图里的黑缝）。
  // 先在索引行下沿做一个 26 单位的透明→纸色渐变过渡，再从 listTop 起整块铺实纸色，
  // 行永远画在实纸上；场景只留在渐变上方可见。
  const double fadeHeight = 44;
  final double fadeTop = listTop - fadeHeight;
  const int steps = 13;
  for (int step = 0; step < steps; step++) {
    final double t = (step + 1) / steps;
    c.fill(
      Rect.fromLTWH(0, fadeTop + step * (fadeHeight / steps),
          portraitDesignWidth, fadeHeight / steps + .5),
      <Object?>[.075, .110, .094, t],
    );
  }
  c.fill(Rect.fromLTWH(0, listTop, portraitDesignWidth, math.max(0, c.height - listTop)),
      <Object?>[.075, .110, .094, 1]);
  c.beginContent(listTop);
  if (archive.rows.isEmpty) {
    if (archive.emptyNotice.isNotEmpty) {
      c.text(archive.emptyNotice, 23, listTop + 16,
          size: 11, width: 347, color: c.muted);
    }
  } else {
    final double slotY = listTop + portraitRowHeight;
    final (int first, int last) = c.visibleRows(slotY, portraitRowHeight, total);
    final int current = position.round().clamp(0, math.max(0, total - 1));
    for (int row = first; row < last; row++) {
      if (row < 0 || row >= total) {
        continue;
      }
      final double y = slotY + (row - position) * portraitRowHeight;
      final double distance = (row - position).abs();
      final bool isCurrent = row == current;
      if (isCurrent) {
        c.fill(Rect.fromLTWH(23, y, 347, portraitRowHeight - 2), c.surface);
        c.fill(Rect.fromLTWH(23, y, 2, portraitRowHeight - 2), c.amber);
      }
      final double alpha = (.85 - distance * .13).clamp(.2, .85);
      final List<Object?> color = <Object?>[.925, .933, .886, alpha];
      c.text(_pad(row + 1), 27, y + 19, size: 8, width: 24, color: c.muted);
      c.text(archive.rows[row].title, 56, y + 14,
          size: isCurrent ? 14 : 13, width: 292, weight: 'regular', color: color);
      if (isCurrent) {
        c.icon('right', 359, y + 16, size: 14, color: c.amber);
      }
      c.hit(
        Rect.fromLTWH(23, y, 347, portraitRowHeight),
        isCurrent || row == archive.index ? 'open' : 'music:index:$row',
        archive.rows[row].title,
      );
    }
  }
  c.endContent();
  // 列表底与播放条之间的分隔（Qt `{0,top,393,.6}`）。
  c.fill(Rect.fromLTWH(0, bottom, portraitDesignWidth, .6), c.line);
}

void _playerAndNav(
  PortraitCanvas c, {
  required PortraitPlayer player,
  required PortraitNav nav,
  required double top,
}) {
  final double h = c.height;
  c.fill(Rect.fromLTWH(0, top, portraitDesignWidth, math.max(0, h - top)), c.paper);
  c.fill(Rect.fromLTWH(0, top, portraitDesignWidth * player.fraction, 2), c.amber);

  // 封面 34×34（Qt `{20, top+15, 34, 34}`），没有真实封面就留空槽，不画假图。
  final Rect cover = Rect.fromLTWH(20, top + 15, 34, 34);
  c.fill(cover, c.surface);
  if (player.cover.isNotEmpty) {
    c.image(player.cover, cover);
  }
  c.border(cover, c.line);

  c.text(player.hasTrack ? player.title : '未在播放', 65, top + 13,
      size: 13, width: 202, weight: 'demibold');
  c.text(player.hasTrack ? player.artist : '选择一首曲目开始', 65, top + 35,
      size: 10, width: 202, color: c.muted);
  c.hit(Rect.fromLTWH(60, top + 8, 207, 48), 'player:open', '打开播放器');

  // 播放/暂停圆钮（Qt PlayerBar::appendPlayButton 的圆形按钮）。
  final double cx = 295 + 20;
  final double cy = top + 34;
  // sweep 必须严格小于 2π：Flutter 的 Path.arcTo 在整圆（2π）时会退化成空路径，
  // 环就画不出来（v101 实机里只剩播放三角形）。
  c.commands.add(<Object?>['arc', cx, cy, 20, 0, math.pi * 2 - .02, 1.2, c.ink]);
  c.icon(player.playing ? 'pause' : 'play', cx - 7.5, cy - 7.5, size: 15, color: c.ink);
  c.hit(Rect.fromLTWH(291, top + 10, 48, 48), 'player:toggle', player.playing ? '暂停' : '播放');

  c.icon('next', 341, cy - 10, size: 20, color: c.ink);
  c.hit(Rect.fromLTWH(331, top + 12, 44, 44), 'player:next', '下一首');

  final double navTop = top + 67;
  final double navHeight = math.max(0, h - portraitGestureInset - navTop);
  if (navHeight <= 0) {
    c.field('playerBounds', Rect.fromLTWH(0, top, portraitDesignWidth, math.max(0, h - top)));
    return;
  }
  c.fill(Rect.fromLTWH(0, navTop, portraitDesignWidth, .7), c.line);
  final double cell = portraitDesignWidth / PortraitNav.values.length;
  for (int index = 0; index < PortraitNav.values.length; index++) {
    final PortraitNav item = PortraitNav.values[index];
    final double x = cell * index;
    final bool selected = item == nav;
    if (selected) {
      c.fill(Rect.fromLTWH(x + 12, navTop, cell - 24, 2), c.amber);
    }
    c.centered(item.title, x + cell / 2, navTop + 15, 13,
        selected ? 'demibold' : 'regular', selected ? c.ink : c.muted);
    c.centered(item.code, x + cell / 2, navTop + 31, 7, 'regular', c.muted);
    if (index > 0) {
      c.fill(Rect.fromLTWH(x, navTop + 10, .6, 23), c.line);
    }
    c.hit(Rect.fromLTWH(x, navTop, cell, navHeight), item.action, item.title);
  }
  c.field('playerBounds', Rect.fromLTWH(0, top, portraitDesignWidth, math.max(0, h - top)));
}

String _pad(int value) => value.toString().padLeft(2, '0');
