import 'dart:math' as math;

import 'package:flutter/rendering.dart';

import 'portrait_canvas.dart';

/// 歌曲百科页（竖屏；横屏由 `_paintPortraitPageInLandscape` 复用同一份命令流）。
///
/// Qt 真值：`Qt/src/MusicLibrary.cpp:591-598` 给歌曲详情补 `wiki`
/// （`api.call("wiki", {id})`，返回的是一段 `标签：值` 的纯文本）；正文为空时
/// 页面显示「暂无歌曲百科」，读取中/失败也各有状态串。插件平台之外（塞壬/本地）
/// 没有百科接口，这里照样画，只是正文为空、状态串来自 controller 的诚实文案。
const double portraitWikiLineGap = 16;

/// 打开歌曲百科页的动作（参数：`trackId`，可选 `title`/`artist`/`cover`）。
const String portraitWikiOpenAction = 'music:wiki';

/// 页头 + 封面块的高度（下一段正文从这里开始）。
const double portraitWikiBodyTop = 236;

/// 一首歌的百科页。
///
/// - [title]/[artist]/[cover] 来自当前曲目；
/// - [lines] 是已经按行切好的百科正文（controller 的 `wikiLines`）；
/// - [status] 是「正在读取…/塞壬唱片不提供歌曲百科/…」这类状态串，正文为空时显示；
/// - [startLine] 给将来的翻页留口（只画从这一行起的正文）。
void paintPortraitWikiPage(
  PortraitCanvas c, {
  required String title,
  required String artist,
  required String cover,
  required List<String> lines,
  required String status,
  required bool loading,
  int startLine = 0,
  String backAction = 'back',
}) {
  c.fill(Rect.fromLTWH(0, 0, c.gridWidth, c.height), c.paper);
  c.header(title.isEmpty ? '歌曲百科' : title, back: true, backAction: backAction);

  // 封面块：与歌手页/专辑页同一套几何（20,128 起 96）。
  const double coverSize = 96;
  final Rect artwork = const Rect.fromLTWH(20, 128, coverSize, coverSize);
  c.fill(artwork, c.surface);
  if (cover.isNotEmpty) {
    c.image(cover, artwork);
  }
  c.border(artwork, c.line);

  final double textLeft = artwork.right + 16;
  final double textWidth = c.gridWidth - textLeft - 20;
  c.text('SONG WIKI', textLeft, 130, size: 8, width: textWidth, color: c.muted);
  c.paragraph(title.isEmpty ? '未命名曲目' : title, textLeft, 144,
      size: 20, width: textWidth, weight: 'demibold', maximumLines: 2);
  c.paragraph(artist.isEmpty ? '未知歌手' : artist, textLeft, 190,
      size: 11, width: textWidth, color: c.muted, maximumLines: 1);

  c.section(portraitWikiBodyTop - 34, '歌曲百科', 'WIKI / ${lines.length}');

  c.beginContent(portraitWikiBodyTop);
  if (lines.isEmpty) {
    // 诚实状态：没有正文就直说，不用占位数据凑版面。
    c.paragraph(status.isEmpty ? '暂无歌曲百科' : status, 20, portraitWikiBodyTop + 8,
        size: 12, width: c.gridWidth - 40, color: c.muted, maximumLines: 4);
    if (loading) {
      c.text('正在读取…', 20, portraitWikiBodyTop + 70, size: 10, color: c.muted);
    }
  } else {
    double y = portraitWikiBodyTop + 4;
    for (int index = math.max(0, startLine); index < lines.length; index++) {
      final String line = lines[index];
      if (y > c.contentBottom) {
        break;
      }
      final int colon = line.indexOf('：');
      if (colon > 0 && colon < line.length - 1) {
        c.text(line.substring(0, colon), 20, y,
            size: 10, width: c.gridWidth - 40, weight: 'demibold', color: c.muted);
        y = c.paragraph(line.substring(colon + 1), 20, y + 15,
            size: 13, width: c.gridWidth - 40);
      } else {
        y = c.paragraph(line, 20, y, size: 13, width: c.gridWidth - 40);
      }
      y += portraitWikiLineGap;
    }
    if (status.isNotEmpty) {
      c.text(status, 20, math.min(y + 4, c.contentBottom - 14),
          size: 10, width: c.gridWidth - 40, color: c.muted);
    }
  }
  c.endContent();
  c.finish();
}
