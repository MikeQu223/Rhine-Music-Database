/// 竖屏（compact）「唱片档案」详情页与「歌词」页：命令流排版，不建 widget。
///
/// 真值来源（几何/层级逐条对齐，C++ 语法改写为 Dart 命令流）：
/// - `Qt/src/ResponsiveHudPages.cpp:173-288` song()：档案类型标签与序号、两行大标题、
///   艺人/专辑、状态点、进度条 + 刻度、传输环，以及歌词/模式/队列/更多四入口。
/// - `Qt/src/ResponsiveLyrics.cpp:49-108` progressRow/transportRow 与
///   `:115-125` lyricsPlayer()、`:127-234` lyrics()：进度行几何、正文 30 / 译文 17 /
///   行间 20 的行距体系、当前行强调与阅读区上下边缘渐隐、行命中 `player:lyric-line:<i>`。
/// - `Qt/src/ResponsiveHudLayout.cpp:303-322`：沉浸播放条的 5 键排布（x = 26 + i*73，
///   播放键圆心同一行）与 `seek` / `playerBounds` 字段。
///
/// 只做「把一份输入排版成命令流 + 命中/字段」：滚动、跟随、seek 由宿主解释 actions
/// 与 fields，本文件不持有播放状态。纵向全部由 `c.height` 推出（629 与 854 都成立），
/// 所有区间先夹再画，不出现负高度/NaN。
library;

import 'dart:math' as math;
import 'dart:ui' show Rect;

import 'portrait_canvas.dart';

/// 393 设计网格宽。
const double _gridWidth = 393;

/// 正文左右留白（Qt 的 20 / 353 对）。
const double _gutter = 20;
const double _bodyWidth = 353;

/// 毫秒 → mm:ss（Qt `MusicData::pad`，PlayerBar.cpp:8-12 的同款）。
String _clock(double ms) {
  final double value = ms.isFinite && ms > 0 ? ms : 0;
  final int seconds = (value / 1000).floor();
  return '${_pad(seconds ~/ 60)}:${_pad(seconds % 60)}';
}

String _pad(int value) => value.toString().padLeft(2, '0');

/// 0..1 夹取（`double.clamp` 返回 num，这里保持 double 口径）。
double _unit(double value) => value.isNaN ? 0 : (value < 0 ? 0 : (value > 1 ? 1 : value));

/// 档案类型标签（Qt 的 “TRACK RECORD / 唱片档案”，按 kind 换抬头）。
String _sectionLabel(String kind) => switch (kind) {
      'album' => 'ALBUM ARCHIVE / 专辑档案',
      'playlist' => 'PLAYLIST ARCHIVE / 播放列表',
      _ => 'TRACK RECORD / 唱片档案',
    };

/// 艺人 / 专辑 次要信息，缺一项就不留多余分隔符。
String _metaLine(String artist, String album) {
  if (artist.isEmpty) {
    return album;
  }
  if (album.isEmpty) {
    return artist;
  }
  return '$artist   /   $album';
}

/// 唱片档案（详情）页。返回前必须调用 c.finish()。
///
/// 几何对齐参考图（1206×2622 设备 = 393×854 网格）：顶部只有一枚居中的关闭 X，
/// 没有标题栏；下面是方形唱片卡、档案行、两行大标题、艺人/专辑、状态行，
/// 再往下从底往上锚定「进度条 → 传输三键 → 四入口」。短屏（本机 629）按比例收卡、
/// 收间距，不出现负高度。
void paintPortraitSongPage(
  PortraitCanvas c, {
  required String title,
  required String artist,
  required String album,
  required String kind,
  required String stamp,
  required String cover,
  required bool playing,
  required bool favourite,
  required double positionMs,
  required double durationMs,
  required String lyricPreview,
  required bool lyricsAvailable,
}) {
  final double h = c.height;

  // 整页铺纸色：竖屏详情是沉浸页，绝不把身后的 3D 唱片透出来（v101 实机串页）。
  c.fill(Rect.fromLTWH(0, 0, _gridWidth, math.max(0, h)), c.paper);

  // 关闭：参考图是顶部居中的一枚 X，没有「RHINE LAB / 标题」页头。
  c.icon('close', _gridWidth / 2 - 9, 34, size: 18, color: c.ink);
  c.hit(Rect.fromLTWH(_gridWidth / 2 - 40, 16, 80, 52), 'back', '关闭');

  // 唱片卡：正方形居中，最长边 312（参考值），短屏按 .38h 收。
  final double side = math.max(120, math.min(312, h * .38));
  final Rect card = Rect.fromLTWH((_gridWidth - side) / 2, 84, side, side);
  c.fill(card, c.surface);
  if (cover.isNotEmpty) {
    c.image(cover, card);
  }
  c.border(card, c.line);

  // 档案行：类型标签 + 右上序号，行下一道细线。
  double y = card.bottom + 16;
  c.text(_sectionLabel(kind), _gutter, y, size: 8, width: 240, color: c.muted);
  if (stamp.isNotEmpty) {
    c.rightText(stamp, 373, y, 8, 'regular', c.ink);
  }
  c.fill(Rect.fromLTWH(_gutter, y + 14, _bodyWidth, .6), c.line);
  y += 26;

  // 两行大标题（超出省略号）+ 艺人/专辑 + 收藏状态。
  y = c.paragraph(
    title,
    _gutter,
    y,
    size: 25,
    width: _bodyWidth,
    weight: 'demibold',
    maximumLines: 2,
    lineSpacing: 1.2,
  );
  final String meta = _metaLine(artist, album);
  y += 6;
  if (meta.isNotEmpty) {
    c.text(meta, _gutter, y, size: 11, width: _bodyWidth - 56, color: c.muted);
  }
  c.icon(favourite ? 'heart-filled' : 'heart', 350, y - 4,
      size: 18, color: favourite ? c.ink : c.muted);
  y += 24;

  // 状态行：琥珀圆点 + 正在播放/已暂停；右侧音频规格本版无真值，留空不编造。
  c.commands.add(<Object?>['ellipse', c.amber, _gutter + 2, y + 5, 5, 5]);
  c.text(playing ? '正在播放' : '已暂停', _gutter + 12, y, size: 8, width: 160, color: c.muted);
  y += 18;

  _songFooterRow(c, top: math.max(y + 40, h - 12) - 32);
  _songTransportRow(c, center: math.max(y + 40, h - 12) - 76, playing: playing);
  final double barY = math.max(y + 8, math.max(y + 40, h - 12) - 76 - 52);
  _songProgressRow(
    c,
    barY: barY,
    lyricPreview: lyricPreview,
    positionMs: positionMs,
    durationMs: durationMs,
  );

  c.finish();
}

/// 进度行：歌词预览 + 轨道/已播/游标 + 刻度 + 两端时间（左已播、右剩余）。
void _songProgressRow(
  PortraitCanvas c, {
  required double barY,
  required String lyricPreview,
  required double positionMs,
  required double durationMs,
}) {
  if (lyricPreview.isNotEmpty) {
    c.icon('lyrics-lines', _gutter, barY - 22, size: 11, color: c.muted);
    c.text(lyricPreview, _gutter + 18, barY - 21,
        size: 10, width: _bodyWidth - 18, color: c.muted);
  }
  final double fraction =
      durationMs.isFinite && durationMs > 0 ? _unit(positionMs / durationMs) : 0;
  c.fill(Rect.fromLTWH(_gutter, barY, _bodyWidth, 2), c.line);
  if (fraction > 0) {
    c.fill(Rect.fromLTWH(_gutter, barY, _bodyWidth * fraction, 2), c.amber);
  }
  c.fill(Rect.fromLTWH(_gutter - 1.5 + _bodyWidth * fraction, barY - 4, 3, 10), c.ink);
  for (int tick = 0; tick <= 20; tick++) {
    c.fill(
      Rect.fromLTWH(_gutter + tick * 17.6, barY + 6, .6, tick % 5 == 0 ? 6 : 3),
      c.line,
    );
  }
  c.field('seek', Rect.fromLTWH(15, barY - 12, 361, 26));
  c.text(_clock(positionMs), _gutter, barY + 16, size: 11, width: 120, color: c.muted);
  final double remaining =
      durationMs.isFinite && durationMs > positionMs ? durationMs - positionMs : 0;
  c.rightText('-${_clock(remaining)}', 373, barY + 16, 11, 'regular', c.muted);
}

/// 传输三键：上一首 / 居中的圆环播放键 / 下一首。
void _songTransportRow(PortraitCanvas c, {required double center, required bool playing}) {
  final double cx = _gridWidth / 2;
  c.commands.add(<Object?>['arc', cx, center, 26, 0, math.pi * 2 - .02, 1.2, c.ink]);
  c.icon(playing ? 'pause' : 'play', cx - 11, center - 11, size: 22, color: c.ink);
  c.icon('prev', cx - 104, center - 12, size: 24, color: c.ink);
  c.icon('next', cx + 80, center - 12, size: 24, color: c.ink);
  c.hit(Rect.fromLTWH(cx - 128, center - 26, 48, 52), 'player:prev', '上一首');
  c.hit(Rect.fromLTWH(cx - 34, center - 34, 68, 68), 'player:toggle', playing ? '暂停' : '播放');
  c.hit(Rect.fromLTWH(cx + 56, center - 26, 48, 52), 'player:next', '下一首');
}

/// 底部四入口：歌词 / 随机播放 / 播放队列 / 更多。
void _songFooterRow(PortraitCanvas c, {required double top, bool lyricsAvailable = true}) {
  c.fill(Rect.fromLTWH(_gutter, top, _bodyWidth, .6), c.line);
  const List<String> labels = <String>['歌词', '随机播放', '播放队列', '更多'];
  const List<String> icons = <String>['lyrics-lines', 'shuffle', 'queue-note', 'more'];
  final List<String> actions = <String>[
    lyricsAvailable ? 'player:lyrics' : '',
    'player:mode',
    'player:open',
    'mobile:song-options',
  ];
  const List<String> hitLabels = <String>['打开全屏歌词', '切换播放模式', '播放队列', '歌曲更多操作'];
  final double cell = _bodyWidth / 4;
  for (int index = 0; index < labels.length; index++) {
    final double x = _gutter + cell * index;
    c.icon(icons[index], x + 4, top + 15, size: 14, color: c.muted);
    c.text(labels[index], x + 24, top + 15, size: 10, width: cell - 26, color: c.muted);
    if (actions[index].isNotEmpty) {
      c.hit(Rect.fromLTWH(x - 2, top + 4, cell - 4, 40), actions[index], hitLabels[index]);
    }
  }
}

/// 歌词页（沉浸播放条 + 滚动歌词）。返回前必须调用 c.finish()。
void paintPortraitLyricsPage(
  PortraitCanvas c, {
  required String title,
  required String artist,
  required String cover,
  required bool playing,
  required double positionMs,
  required double durationMs,
  required List<(int startMs, String text, String translation)> lines,
  required int activeLine,
}) {
  final double h = c.height;

  // 歌词页整页铺纸色（Qt 的 lyric 分支：`paperPage || lyric` 全屏 paper），
  // 正文因此始终落在纸面而不是 3D 场景上。
  c.fill(Rect.fromLTWH(0, 0, _gridWidth, math.max(0, h)), c.paper);
  // 顶部：只有一枚居中把手（下拉/点击收起），没有「RHINE LAB / 歌词」页头——
  // 参考图的歌词页是沉浸式全屏歌词，标题区只有封面 + 曲名 + 艺人 + 收藏/更多。
  c.fill(const Rect.fromLTWH(160, 16, 73, 3), c.line);
  c.hit(const Rect.fromLTWH(120, 4, 153, 40), 'player:lyrics-close', '收起歌词');

  const Rect strip = Rect.fromLTWH(_gutter, 40, 44, 44);
  c.fill(strip, c.surface);
  if (cover.isNotEmpty) {
    c.image(cover, strip);
  }
  c.border(strip, c.line);
  c.text(title, 76, 44, size: 13, width: 250, weight: 'demibold');
  c.text(artist, 76, 63, size: 10, width: 250, color: c.muted);
  c.icon('heart', 344, 50, size: 18, color: c.muted);
  c.icon('more', 370, 52, size: 14, color: c.muted);

  // 阅读区：118 起，下沿让给沉浸条。
  //
  // Qt compact 给歌词页留的是固定 250（`contentBottom = m_height - 34 - 250`），
  // 那是按 393×854 的参考机算的。本机网格高只有 ~630，固定 250 会把歌词压成
  // 一条缝（用户 2026-11-19：「歌词部分空间高度不足」）。所以改成按可用高度取
  // 比例：高屏逼近 Qt 的 250，矮屏最少让到 150，歌词永远拿到剩下的全部。
  const double viewTop = 118;
  final double bandHeight = math.min(250, math.max(150, (h - 34) * .30));
  final double bandTop = math.max(viewTop + 96, h - 34 - bandHeight);

  c.contentBottom = bandTop;
  c.beginContent(viewTop);
  _lyricsRows(c, top: viewTop, bottom: bandTop, lines: lines, activeLine: activeLine);
  c.endContent();

  _lyricsBar(c, top: bandTop, playing: playing, positionMs: positionMs, durationMs: durationMs);
  c.finish();
}

/// 逐行歌词：当前行大一号 + ink，其余 muted；译文小字挂在本行正文下方。
void _lyricsRows(
  PortraitCanvas c, {
  required double top,
  required double bottom,
  required List<(int startMs, String text, String translation)> lines,
  required int activeLine,
}) {
  final double height = math.max(0, bottom - top);
  if (lines.isEmpty) {
    // 空状态摆阅读区正中，别贴着顶沿（否则歌词区看起来像没铺开）。
    c.text('暂无歌词 / NO LYRICS', _gutter, top + height / 2 - 8,
        size: 12, width: _bodyWidth, color: c.muted);
    return;
  }

  final int active = activeLine >= 0 && activeLine < lines.length ? activeLine : -1;
  final List<double> tops = <double>[];
  final List<double> heights = <double>[];
  final List<List<String>> bodies = <List<String>>[];
  final List<List<String>> translations = <List<String>>[];
  double cursor = 0;
  for (int index = 0; index < lines.length; index++) {
    final bool isActive = index == active;
    final double size = isActive ? 22 : 18;
    final double lineHeight = isActive ? 30 : 26;
    final String body = lines[index].$2.isEmpty ? '•••' : lines[index].$2;
    final List<String> wrapped =
        c.wrap(body, _bodyWidth, size, isActive ? 'demibold' : 'regular');
    final String source = lines[index].$3;
    final List<String> translated =
        source.isEmpty ? const <String>[] : c.wrap(source, _bodyWidth, 11);
    final double rowHeight = wrapped.length * lineHeight + translated.length * 17;
    tops.add(cursor);
    heights.add(rowHeight);
    bodies.add(wrapped);
    translations.add(translated);
    cursor += rowHeight + 20;
  }

  final double contentHeight = math.max(0, cursor - 20);
  // 没有滚动入参：把当前行摆到阅读区中线，越界时贴住两端（等价 Qt 的 follow 目标）。
  double scroll = active >= 0 ? tops[active] + heights[active] / 2 - height / 2 : 0;
  scroll = scroll.clamp(0, math.max(0, contentHeight - height + 24)).toDouble();

  for (int index = 0; index < lines.length; index++) {
    final double y = top + tops[index] - scroll;
    final double rowHeight = heights[index];
    if (y + rowHeight < top - 12 || y > bottom + 12) {
      continue;
    }
    final bool isActive = index == active;
    final double size = isActive ? 22 : 18;
    final double lineHeight = isActive ? 30 : 26;
    // 上下边缘 36 的渐隐（Qt lyrics() 的 edge 公式），保证滚动进出不生硬。
    final double edge = _unit(
      math.min((y + rowHeight - top) / 36, (bottom - y) / 36),
    );
    final List<Object?> color = List<Object?>.of(isActive ? c.ink : c.muted);
    color[3] = (isActive ? 1.0 : .32) * edge;
    final List<String> body = bodies[index];
    for (int line = 0; line < body.length; line++) {
      c.text(body[line], _gutter, y + line * lineHeight,
          size: size, width: _bodyWidth, weight: isActive ? 'demibold' : 'regular', color: color);
    }
    final List<Object?> translated = List<Object?>.of(color);
    translated[3] = (isActive ? 1.0 : .32) * edge * .7;
    final List<String> translation = translations[index];
    for (int line = 0; line < translation.length; line++) {
      c.text(translation[line], _gutter, y + body.length * lineHeight + line * 17,
          size: 11, width: _bodyWidth, color: translated);
    }
    // 下标必须是 lines 的真实下标：宿主用它换算真实 seek 目标。
    final double hitTop = math.max(top, y - 8);
    final double hitBottom = math.min(bottom, y + rowHeight + 10);
    if (hitBottom - hitTop > 8) {
      c.hit(Rect.fromLTWH(12, hitTop, 369, hitBottom - hitTop), 'player:lyric-line:$index',
          body.join(' '));
    }
  }
}

/// 沉浸播放条：进度 + 两端时间 + 五键（heart / prev / play / next / queue）。
void _lyricsBar(
  PortraitCanvas c, {
  required double top,
  required bool playing,
  required double positionMs,
  required double durationMs,
}) {
  final double h = c.height;
  c.fill(Rect.fromLTWH(0, top, _gridWidth, .6), c.line);

  // 沉浸条几何照抄 Qt compact `player(c, immersive=true)`
  // （ResponsiveHudLayout.cpp:303-323）：进度 top+19、时间 top+32、
  // 五个按键 top+65..117。整条高度由调用方给的 bandHeight 决定，
  // 多出来的空间留在最下方，歌词因此拿到其余全部高度。
  final double barY = top + 19;
  final double fraction =
      durationMs.isFinite && durationMs > 0 ? _unit(positionMs / durationMs) : 0;
  c.fill(Rect.fromLTWH(26, barY, 341, 2), c.line);
  if (fraction > 0) {
    c.fill(Rect.fromLTWH(26, barY, 341 * fraction, 2), c.amber);
  }
  c.fill(Rect.fromLTWH(24.5 + 341 * fraction, barY - 5, 3, 12), c.ink);
  for (int tick = 0; tick <= 20; tick++) {
    c.fill(
      Rect.fromLTWH(26 + tick * 17.05, barY + 4, .6, tick % 5 == 0 ? 6 : 3),
      c.line,
    );
  }
  c.field('seek', Rect.fromLTWH(26, top + 9, 341, 24));
  c.text(_clock(positionMs), 26, top + 32, size: 10, width: 100, color: c.muted);
  c.rightText(_clock(durationMs), 367, top + 32, 10, 'regular', c.muted);

  const List<String> icons = <String>['heart', 'prev', '', 'next', 'queue'];
  const List<String> routes = <String>['', 'player:prev', 'player:toggle', 'player:next', 'player:open'];
  final List<String> labels = <String>[
    '喜欢',
    '上一首',
    playing ? '暂停' : '播放',
    '下一首',
    '播放队列',
  ];
  final double rowCenter = top + 90;
  for (int index = 0; index < 5; index++) {
    final double x = 26 + index * 73;
    final double centerX = x + 22;
    if (index == 2) {
      // 整圆必须少画一点：sweep 恰好 2π 时 Path.arcTo 会退化，环画不出来。
      c.commands.add(
        <Object?>['arc', centerX, rowCenter, 26, 0, math.pi * 2 - .02, 1.2, c.line],
      );
      c.icon(playing ? 'pause' : 'play', centerX - 11, rowCenter - 11, size: 22, color: c.ink);
    } else if (index == 0) {
      // 喜欢状态不在本页入参里：只画空心，不发 music:like-current。
      c.icon(icons[index], x + 10, top + 79, size: 23, color: c.muted);
    } else {
      c.icon(icons[index], x + 10, top + 79, size: 23, color: c.ink);
    }
    if (routes[index].isNotEmpty) {
      c.hit(Rect.fromLTWH(x, top + 65, 44, 52), routes[index], labels[index]);
    }
  }
  c.field('playerBounds', Rect.fromLTWH(0, top, _gridWidth, math.max(0, h - top)));
}
