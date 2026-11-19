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
import '../scale/hud_scale.dart';
import 'portrait_canvas.dart';

/// 393 网格：设计稿宽（Qt `ResponsiveHudLayout` 的 393）。
const double portraitDesignWidth = 393;

/// 舞台像素 / 网格。
///
/// Qt 原文是 `m_unit = stageWidth / 393`（393 网格铺满舞台宽），屏幕一宽
/// 「1 网格 = 多少 dp」就跟着涨——本机 1.94dp，参考图那台约 1.07dp。现在按
/// [HudScale.portraitUnitFactor] 把网格压回 clamp 后的 dp 带（≤1.3dp）；横向多出来
/// 的空间靠 [portraitGridWidth]（页面更宽、元素尺寸不变）消化，不缩页面也不居中留白。
/// [stageScale] 缺省 0 表示「不压缩」，仅供不知窗口缩放比的旧调用点使用。
double portraitUnit(double stageWidth, {double stageScale = 0}) =>
    stageScale > 0 ? HudScale.portraitUnit(stageWidth, stageScale) : stageWidth / portraitDesignWidth;

/// 页面可用的网格宽度（网格单位）。
///
/// 1 网格被 DPI 带夹小之后横向网格数比设计稿的 393 多（本机 586），页面必须按这个
/// 宽度算右缘才铺满舞台；[stageScale] 缺省 0 表示「不压缩」，退回设计稿宽度。
double portraitGridWidth(double stageWidth, {double stageScale = 0}) =>
    stageScale > 0
        ? HudScale.portraitGridWidth(stageWidth, stageScale)
        : portraitDesignWidth;

/// 393 网格里的可视高度（Qt `m_height = 1080 / m_unit`）。
double portraitGridHeight(double stageHeight, double unit) => stageHeight / unit;

/// 行高、手势内缩、播放条高度（Qt ResponsiveHudLayout 的常量）。
const double portraitRowHeight = 48;
const double portraitGestureInset = 34;

/// 底部「迷你播放条 + 底栏 + 手势区」占的设计网格高度。
///
/// Qt 里播放条顶 = `c.contentBottom`，导航条 = 顶 + 67，导航条高
/// `max(0, h - 34 - 导航条)`（`ResponsiveHudLayout.cpp:329-420`）；三者相加
/// 恒为 144，与 `m_height` 无关。设置/检索这类整页只铺到 `h - 144`。
const double portraitFooterHeight = 144;

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

/// 列表带顶：竖屏内容区按 1:1 切成 3D 区与列表区。
///
/// 上半屏（`h * .5`）留给 3D 场景与列表滚动窗口，下半屏给列表行与播放条；
/// [BasicHudSurface] 的竖屏场景矩形用同一条分割线（`stageHeight * .5`），
/// 绘制与命中不会各算一份。
double portraitListTop(double height) => height * .5;

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

  // 播放条/底栏永远贴在舞台底部（与 paintPortraitShell 同源）；列表带只决定
  // 上半屏的 3D/列表分割线，二者不能再用「listTop + 四行」联动。
  canvas.contentBottom = math.max(0, h - portraitFooterHeight);

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

/// 竖屏「终端页」页头（Qt `ResponsiveHudLayout.cpp:163-193` 的 terminalPage 分支）。
///
/// 与主页品牌的差别：第二行写 `AUDIO TERMINAL`（主页是 `MUSIC ARCHIVE / 音乐资料库`），
/// 右侧是短码 `RL–004`；大标题下多一行「琥珀编号块 + 英文标识」，再一条墨线与
/// 左缘 16 步长的校准刻度（刻度只做视觉定位，不参与命中）。
///
/// 必须在 `canvas.contentBottom` 设好之后调用：刻度一直画到内容底。
void paintPortraitTerminalHeader(
  PortraitCanvas c, {
  required String title,
  required String code,
  required String identifier,
}) {
  c.text('RHINE LAB', 23, 22, size: 17, width: 115, weight: 'bold');
  c.text('AUDIO TERMINAL', 23, 43, size: 7, width: 115, color: c.muted);
  final double w = c.gridWidth;
  c.rightText('RL–004', w - 23, 29, 7, 'regular', c.muted);
  c.text(title, 20, 66, size: 23, width: w - 103, weight: 'demibold');
  c.fill(Rect.fromLTWH(20, 101, 25, 14), c.amber);
  c.centered(code, 32.5, 108, 8, 'demibold', c.ink);
  c.text(identifier, 53, 104, size: 7, width: w - 128, color: c.muted);
  c.fill(Rect.fromLTWH(20, 120, w - 40, .6), c.ink);
  final List<Object?> calibration = <Object?>[...c.line]..[3] = .6;
  for (double tick = 132; tick < c.contentBottom; tick += 16) {
    c.fill(Rect.fromLTWH(8, tick, 4, .5), calibration);
  }
}

/// 竖屏整页外壳：纸色铺满 + （可选）终端页头 + 迷你播放条 + 底栏。
///
/// 给「内容由真实 widget 承担、只有 chrome 归 HUD」的页面用（设置整页）。
/// 上界是 `h - portraitFooterHeight`，与 `_playerAndNav` 的播放条顶同源，
/// 于是 widget 层与 HUD 层不会各算一份底部高度。
PortraitFrame paintPortraitShell(
  PortraitCanvas canvas, {
  required PortraitPlayer player,
  /// 底栏高亮项；null = 本页不属于任何底栏 tab（Qt 插件页 `active=""`）。
  PortraitNav? nav,
  String title = '',
  String code = '',
  String identifier = '',
  /// 自定义页头（插件页用通用页头 `ResponsiveHudCanvas::header`，
  /// 而不是终端页头）；给了它就不画 [title] 的终端页头。
  void Function(PortraitCanvas canvas)? header,
  /// 内容区（在纸色与页头之后、播放条之前调用）；插件页自己的内容在 widget 层，
  /// 这里传 null。
  void Function(PortraitCanvas canvas, double pageBottom)? content,
}) {
  final double h = canvas.height;
  final double top = math.max(0, h - portraitFooterHeight);
  canvas.contentBottom = top;
  canvas.fill(Rect.fromLTWH(0, 0, canvas.gridWidth, h), canvas.paper);
  if (header != null) {
    header(canvas);
  } else if (title.isNotEmpty) {
    paintPortraitTerminalHeader(
      canvas,
      title: title,
      code: code,
      identifier: identifier,
    );
  }
  content?.call(canvas, top);
  _playerAndNav(canvas, player: player, nav: nav, top: top);
  canvas.finish();
  return PortraitFrame(
    commands: canvas.commands,
    hits: canvas.hits,
    fields: canvas.fields,
    listTop: top,
  );
}

void _brand(PortraitCanvas c) {
  final double w = c.gridWidth;
  c.text('RHINE LAB', 23, 22, size: 17, width: 200, weight: 'bold');
  c.text('MUSIC ARCHIVE / 音乐资料库', 23, 43, size: 7, width: 240, color: c.muted);
  c.rightText('AUDIO TERMINAL / RL–004', w - 23, 29, 7, 'regular', c.muted);
  c.fill(Rect.fromLTWH(23, 58, w - 46, .6), c.line);
}

void _tabs(PortraitCanvas c, PortraitArchive archive) {
  final List<PortraitTab> tabs = archive.tabs;
  if (tabs.isEmpty) {
    return;
  }
  final double tabWidth = (c.gridWidth - 46) / tabs.length;
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
  final double w = c.gridWidth;
  c.text(archive.title, 23, 123,
      size: 23, width: archive.canPlayAll ? w - 143 : w - 48, weight: 'bold');
  if (archive.canPlayAll && archive.total > 0) {
    c.icon('play', w - 105, 126, size: 15);
    c.text('播放全部', w - 84, 127, size: 10, width: 74);
    c.hit(Rect.fromLTWH(w - 113, 114, 94, 44), 'music:play-loaded', '播放全部');
  }
  c.text('上下滑动浏览 / TRACK INDEX', 23, listTop - 18, size: 8, width: 240, color: c.muted);
  final String counter = archive.total == 0
      ? '00 / 00'
      : '${_pad(archive.index + 1)} / ${_pad(archive.total)}';
  c.rightText(counter, w - 23, listTop - 18, 8, 'regular', c.ink);
  c.fill(Rect.fromLTWH(23, listTop - 4, w - 46, .7), c.ink);
}

void _list(
  PortraitCanvas c,
  PortraitArchive archive,
  double listTop,
  double position,
  int total,
) {
  final double bottom = c.height - portraitFooterHeight;
  // 3D 场景矩形在 1:1 分割线处结束；不在列表带铺纸色就会看到场景下沿一条硬切边。
  // 先在索引行下沿做一个 44 单位的透明→纸色渐变过渡，再从 listTop 起整块铺实纸色，
  // 行永远画在实纸上；场景只留在渐变上方可见。
  const double fadeHeight = 44;
  final double fadeTop = listTop - fadeHeight;
  const int steps = 13;
  List<Object?> wash(double alpha) =>
      <Object?>[c.paper[0], c.paper[1], c.paper[2], alpha];
  for (int step = 0; step < steps; step++) {
    final double t = (step + 1) / steps;
    c.fill(
      Rect.fromLTWH(0, fadeTop + step * (fadeHeight / steps),
          c.gridWidth, fadeHeight / steps + .5),
      wash(t),
    );
  }
  c.fill(Rect.fromLTWH(0, listTop, c.gridWidth, math.max(0, c.height - listTop)), wash(1));
  c.beginContent(listTop);
  if (archive.rows.isEmpty) {
    if (archive.emptyNotice.isNotEmpty) {
      c.text(archive.emptyNotice, 23, listTop + 16,
          size: 11, width: c.gridWidth - 46, color: c.muted);
    }
  } else {
    // 当前行固定在「第二槽」是 Qt 的原始版式（上方留一行给「上一首」，滚动时顺手滑出）。
    // 但列表在顶端时 position = 0，第二槽会把第一槽空着——一屏四行的带子只剩三行
    // （用户 2026-11-18 就是在说这个「只显示三个」）。所以槽位偏移随 position 从 0
    // 连续长到一整行：顶端四行铺满，往下滚之后恢复「上一行在上方」的原始外观。
    final double slotY = listTop + portraitRowHeight * position.clamp(0.0, 1.0);
    // 可见行区间必须跟着滚动位置走。
    // 旧写法用 `c.visibleRows(slotY, …)`，first 恒被算成 0（slotY 比裁剪顶低一行），
    // 于是永远只画 0..2 三行；位置一滚走，这三行被裁掉就剩一片空列表
    // （用户 2026-11-18：「列表只显示三个，再往下滑动就黑了」）。
    // 行窗口下界比当前行多留一行（上一首），上界按实际列表高度补齐。
    // 可见行数由「分割线到播放条上沿」的实际高度决定：1:1 之后列表区高于四行，
    // 仍写死 +4 会在最后一行与播放条之间留下一条空白纸带（用户 2026-11-19）。
    final int visibleRows = math.max(
      1,
      ((bottom - listTop) / portraitRowHeight).ceil(),
    );
    final int first = math.max(0, position.floor() - 1);
    final int last = math.min(total, position.ceil() + visibleRows);
    final int current = position.round().clamp(0, math.max(0, total - 1));
    for (int row = first; row < last; row++) {
      if (row < 0 || row >= total) {
        continue;
      }
      final double y = slotY + (row - position) * portraitRowHeight;
      final double distance = (row - position).abs();
      final bool isCurrent = row == current;
      final double rowWidth = c.gridWidth - 46;
      if (isCurrent) {
        c.fill(Rect.fromLTWH(23, y, rowWidth, portraitRowHeight - 2), c.surface);
        c.fill(Rect.fromLTWH(23, y, 2, portraitRowHeight - 2), c.amber);
      }
      final double alpha = (.85 - distance * .13).clamp(.2, .85);
      // 行标题跟着主题走（原来钉死暗色 ink 的奶油色）：亮色主题下必须换成深墨，
      // 否则浅底浅字同样读不出来。
      final List<Object?> color = <Object?>[c.ink[0], c.ink[1], c.ink[2], alpha];
      c.text(_pad(row + 1), 27, y + 19, size: 8, width: 24, color: c.muted);
      c.text(archive.rows[row].title, 56, y + 14,
          size: isCurrent ? 14 : 13, width: rowWidth - 55, weight: 'regular', color: color);
      if (isCurrent) {
        c.icon('right', c.gridWidth - 34, y + 16, size: 14, color: c.amber);
      }
      c.hit(
        Rect.fromLTWH(23, y, rowWidth, portraitRowHeight),
        isCurrent || row == archive.index ? 'open' : 'music:index:$row',
        archive.rows[row].title,
      );
    }
  }
  c.endContent();
  // 列表底与播放条之间的分隔（Qt `{0,top,393,.6}`）。
  c.fill(Rect.fromLTWH(0, bottom, c.gridWidth, .6), c.line);
}

void _playerAndNav(
  PortraitCanvas c, {
  required PortraitPlayer player,
  PortraitNav? nav,
  required double top,
}) {
  final double h = c.height;
  final double w = c.gridWidth;
  c.fill(Rect.fromLTWH(0, top, w, math.max(0, h - top)), c.paper);
  c.fill(Rect.fromLTWH(0, top, w * player.fraction, 2), c.amber);

  // 封面 34×34（Qt `{20, top+15, 34, 34}`），没有真实封面就留空槽，不画假图。
  final Rect cover = Rect.fromLTWH(20, top + 15, 34, 34);
  c.fill(cover, c.surface);
  if (player.cover.isNotEmpty) {
    c.image(player.cover, cover);
  }
  c.border(cover, c.line);

  final double textWidth = math.max(120, w - 175);
  c.text(player.hasTrack ? player.title : '未在播放', 65, top + 13,
      size: 13, width: textWidth, weight: 'demibold');
  c.text(player.hasTrack ? player.artist : '选择一首曲目开始', 65, top + 35,
      size: 10, width: textWidth, color: c.muted);
  c.hit(Rect.fromLTWH(60, top + 8, textWidth + 5, 48), 'player:open', '打开播放器');

  // 播放/暂停圆钮（Qt PlayerBar::appendPlayButton 的圆形按钮）。
  final double cx = w - 78;
  final double cy = top + 34;
  // sweep 必须严格小于 2π：Flutter 的 Path.arcTo 在整圆（2π）时会退化成空路径，
  // 环就画不出来（v101 实机里只剩播放三角形）。
  c.commands.add(<Object?>['arc', cx, cy, 20, 0, math.pi * 2 - .02, 1.2, c.ink]);
  c.icon(player.playing ? 'pause' : 'play', cx - 7.5, cy - 7.5, size: 15, color: c.ink);
  // 播放钮命中刻意比「下一首」左一点：两者相邻，圆心必须只落在播放钮里。
  c.hit(Rect.fromLTWH(w - 102, top + 10, 46, 46), 'player:toggle', player.playing ? '暂停' : '播放');

  c.icon('next', w - 52, cy - 10, size: 20, color: c.ink);
  c.hit(Rect.fromLTWH(w - 58, top + 12, 44, 44), 'player:next', '下一首');

  final double navTop = top + 67;
  final double navHeight = math.max(0, h - portraitGestureInset - navTop);
  if (navHeight <= 0) {
    c.field('playerBounds', Rect.fromLTWH(0, top, w, math.max(0, h - top)));
    return;
  }
  c.fill(Rect.fromLTWH(0, navTop, w, .7), c.line);
  final double cell = w / PortraitNav.values.length;
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
  c.field('playerBounds', Rect.fromLTWH(0, top, w, math.max(0, h - top)));
}

String _pad(int value) => value.toString().padLeft(2, '0');
