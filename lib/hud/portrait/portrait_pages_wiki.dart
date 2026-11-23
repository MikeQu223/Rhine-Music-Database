import 'dart:math' as math;

import 'package:flutter/rendering.dart';

import '../scale/portrait_rhythm.dart';
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
  double scroll = 0,
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

  // 正文起点跟着节奏走：页头封面的下沿是锚，设计稿的 236 只是基准页取值，
  // 矮屏按 [PortraitRhythm] 收、高屏保持（不缩放字号，只收间距）。
  final double bodyTop =
      PortraitRhythm.below(artwork.bottom, portraitWikiBodyTop, c.height);
  c.section(bodyTop - PortraitRhythm.gap(34, c.height), '歌曲百科',
      'WIKI / ${lines.length}');

  c.beginContent(bodyTop);
  if (lines.isEmpty) {
    // 诚实状态：没有正文就直说，不用占位数据凑版面。
    c.paragraph(status.isEmpty ? '暂无歌曲百科' : status, 20, bodyTop + 8,
        size: 12, width: c.gridWidth - 40, color: c.muted, maximumLines: 4);
    if (loading) {
      c.text('正在读取…', 20, bodyTop + 70, size: 10, color: c.muted);
    }
  } else {
    final double textWidth = c.gridWidth - 40;
    final double gap = PortraitRhythm.gap(portraitWikiLineGap, c.height);
    // 先量一遍每行的高度（换行只取决于 metrics.wrap，与 [PortraitCanvas.paragraph]
    // 同源），才能算出滚动上限；不这样做就只能靠「画到裁剪线就 break 静默截断」，
    // 长词条在矮屏上会直接看不到后半段。
    final List<(String head, String body, double height)> blocks =
        <(String head, String body, double height)>[];
    double total = 0;
    for (int index = math.max(0, startLine); index < lines.length; index++) {
      final String line = lines[index];
      final int colon = line.indexOf('：');
      final bool headed = colon > 0 && colon < line.length - 1;
      final String head = headed ? line.substring(0, colon) : '';
      final String body = headed ? line.substring(colon + 1) : line;
      final double textHeight = c.wrappedLines(body, textWidth, 13) * 13 * 1.5;
      final double height = (headed ? 15.0 : 0.0) + textHeight + gap;
      blocks.add((head, body, height));
      total += height;
    }
    final double visible = math.max(1, c.contentBottom - bodyTop);
    final double maximumScroll = math.max(0, total - visible + 4);
    final double offset = scroll.clamp(0.0, maximumScroll);
    double y = bodyTop + 4 - offset;
    for (final (String head, String body, double height) in blocks) {
      // 完全在裁剪线上方的段直接跳过（只是省命令流，裁切由 beginContent 负责）。
      final bool below = y + height < bodyTop;
      final bool above = y > c.contentBottom + 200;
      if (!below && !above) {
        if (head.isNotEmpty) {
          c.text(head, 20, y, size: 10, width: textWidth,
              weight: 'demibold', color: c.muted);
          c.paragraph(body, 20, y + 15, size: 13, width: textWidth);
        } else {
          c.paragraph(body, 20, y, size: 13, width: textWidth);
        }
      }
      y += height;
    }
    if (status.isNotEmpty && y + 4 < c.contentBottom) {
      c.text(status, 20, y + 4, size: 10, width: textWidth, color: c.muted);
    }
  }
  c.endContent();
  c.finish();
}
