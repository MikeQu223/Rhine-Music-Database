import 'dart:math' as math;

import 'package:flutter/rendering.dart';

import 'portrait_canvas.dart';

/// 专辑信息页的一行（同专辑曲目）。
typedef PortraitAlbumInfoRow = ({String title, String artist, String stamp, String action});

/// 曲目行高（与列表行一致，Lead 用同一份下标记滚动）。
const double portraitAlbumInfoRowStride = 68;

/// 打开专辑信息页的动作（参数：`albumId`，缺省取当前专辑/目录）。
const String portraitAlbumInfoOpenAction = 'music:album-info';

/// 专辑信息页（竖屏；横屏复用同一份命令流）。
///
/// Qt 真值：专辑页走 `MusicDirectory::enterDirectory` 的 `detail` 分支，
/// item 上有 `title/artist/cover/description/date/trackCount`，`songs` 是同专辑曲目。
/// 页面几何按 393 网格：页头（封面 120 + 专辑名/艺人/发行信息）+ 简介 + 曲目行。
/// 没有数据的字段一律留空并显示诚实状态串，不编造发行信息。
void paintPortraitAlbumInfoPage(
  PortraitCanvas c, {
  required String title,
  required String artist,
  required String cover,
  required String date,
  required String description,
  required int trackCount,
  required List<PortraitAlbumInfoRow> songs,
  required String status,
  required bool loading,
  int selectedIndex = -1,
  String backAction = 'back',
}) {
  c.fill(Rect.fromLTWH(0, 0, c.gridWidth, c.height), c.paper);
  c.header(title.isEmpty ? '专辑信息' : title, back: true, backAction: backAction);

  const double coverSize = 120;
  final Rect artwork = const Rect.fromLTWH(20, 128, coverSize, coverSize);
  c.fill(artwork, c.surface);
  if (cover.isNotEmpty) {
    c.image(cover, artwork);
  }
  c.border(artwork, c.line);

  final double textLeft = artwork.right + 16;
  final double textWidth = c.gridWidth - textLeft - 20;
  c.text('ALBUM ARCHIVE', textLeft, 130, size: 8, width: textWidth, color: c.muted);
  c.paragraph(title.isEmpty ? '未命名专辑' : title, textLeft, 144,
      size: 20, width: textWidth, weight: 'demibold', maximumLines: 2);
  c.paragraph(artist.isEmpty ? '未知艺人' : artist, textLeft, 190,
      size: 11, width: textWidth, color: c.muted, maximumLines: 1);
  final String meta = <String>[
    if (date.isNotEmpty) date,
    if (trackCount > 0) '$trackCount 首',
  ].join(' · ');
  c.text(meta.isEmpty ? '—' : meta, textLeft, 208,
      size: 9, width: textWidth, color: c.muted);

  double y = artwork.bottom + 16;
  final String body = description.isEmpty
      ? (status.isEmpty ? '暂无专辑介绍' : status)
      : description;
  y = c.paragraph(body, 20, y,
      size: 11, width: c.gridWidth - 40, color: c.muted, maximumLines: 4);
  if (status.isNotEmpty && description.isNotEmpty) {
    c.text(status, 20, y + 4, size: 10, width: c.gridWidth - 40, color: c.muted);
    y += 20;
  }

  final double sectionY = math.max(y + 16, artwork.bottom + 24);
  c.section(sectionY, '同专辑曲目', 'INDEX / ${songs.length}');
  final double listTop = sectionY + 30;

  c.beginContent(listTop);
  if (songs.isEmpty) {
    c.paragraph(loading ? '正在读取专辑曲目…' : '这张专辑没有可显示的曲目', 20, listTop + 8,
        size: 12, width: c.gridWidth - 40, color: c.muted, maximumLines: 3);
  } else {
    final (int first, int last) = c.visibleRows(listTop, portraitAlbumInfoRowStride, songs.length);
    for (int index = first; index < last; index++) {
      final PortraitAlbumInfoRow row = songs[index];
      c.row(
        listTop + index * portraitAlbumInfoRowStride,
        title: row.title,
        artist: row.artist,
        stamp: row.stamp,
        action: row.action,
        number: '${index + 1}',
        current: index == selectedIndex,
      );
    }
  }
  c.endContent();
  c.finish();
}
