/// 竖屏「歌曲操作」sheet（`lib/hud/portrait/portrait_song_options.dart`）验收测试。
///
/// 真值：`Qt/src/ResponsiveLyrics.cpp:236-276` 的 `optionsSheet()`（清 seek/volume 字段 →
/// 顶边 `max(118., h - 34 - 416)` → surface 填充 + 1 高分隔线 → 「歌曲操作」标题 →
/// 两列按钮网格 `{20+(i%2)*181, y+(i/2)*52, 172, 44}`（y 起于 sheetTop+56）→
/// 元信息行 → 下方 4 行封顶的说明段落）。
///
/// 断言口径：sheet 顶边/高度由画布高度推出（800 高 → 416 / 384）、按钮命中串原样、
/// 元信息行进命令流；字形宽度用固定估算，不校验像素。
library;

import 'dart:ui' show Rect;

import 'package:flutter_test/flutter_test.dart';
import 'package:rhine_music_database/hud/portrait/portrait_canvas.dart';
import 'package:rhine_music_database/hud/portrait/portrait_song_options.dart';
import 'package:rhine_music_database/hud/protocol/hud_hit.dart';

/// 宽度按字符数估算：本组只关心「画了什么 / 发了什么动作」，不校验像素。
final PortraitMetrics _estimateMetrics = PortraitMetrics(
  width: (String value, double size, String weight) => value.length * size * .6,
  wrap: (String value, double limit, double size, String weight) => <String>[value],
  bounds: (String value, double size, String weight) =>
      PortraitGlyphBounds(width: value.length * size * .6, height: size),
);

/// 每 12 个字符强制断一行：用来把说明段落顶到 4 行上限之外。
final PortraitMetrics _chunkedMetrics = PortraitMetrics(
  width: (String value, double size, String weight) => value.length * size * .6,
  wrap: (String value, double limit, double size, String weight) => <String>[
    for (int start = 0; start < value.length; start += 12)
      value.substring(start, start + 12 > value.length ? value.length : start + 12),
  ],
  bounds: (String value, double size, String weight) =>
      PortraitGlyphBounds(width: value.length * size * .6, height: size),
);

PortraitCanvas _canvas({
  bool dark = true,
  double gridWidth = 393,
  double height = 800,
  PortraitMetrics? metrics,
}) =>
    PortraitCanvas(
      metrics: metrics ?? _estimateMetrics,
      unit: 1,
      gridWidth: gridWidth,
      height: height,
      dark: dark,
    );

List<List<Object?>> _ops(PortraitCanvas c, String op) =>
    c.commands.where((List<Object?> command) => command[0] == op).toList();

List<String> _texts(PortraitCanvas c) => <String>[
  for (final List<Object?> command in _ops(c, 'text')) command[1]! as String,
];

/// 说明段落的行：12 号、画在元信息行（y = 556）之下。
List<List<Object?>> _bodyLines(PortraitCanvas c) => _ops(c, 'text')
    .where((List<Object?> command) =>
        command[4] == 12 && (command[3]! as num) >= 556 + 25)
    .toList();

List<HudHit> _hits(PortraitCanvas c, String action) =>
    c.hits.where((HudHit hit) => hit.action == action).toList();

/// 三个按钮 + 元信息行：`exports` 之外还要覆盖 i=0/1/2 的网格位置。
double _paint(
  PortraitCanvas c, {
  List<(String label, String action)> actions = const <(String label, String action)>[
    ('官方客户端 ↗', 'music:official'),
    ('查看评论', 'music:comments'),
    ('添加到歌单', 'music:playlist-add'),
  ],
  String detail = 'Kernel Overflow / 04:21',
  String detailBody = '',
  double? scrollOffset,
}) =>
    paintPortraitSongOptions(
      c,
      actions: actions,
      detail: detail,
      detailBody: detailBody,
      scrollOffset: scrollOffset,
    );

void main() {
  group('sheet 几何（ResponsiveLyrics.cpp:240-242）', () {
    test('800 高画布：返回高度 416，顶边 = h - 416，填充铺到屏幕底', () {
      final PortraitCanvas c = _canvas();
      final double sheetHeight = _paint(c);
      expect(sheetHeight, 416);
      expect(c.height - sheetHeight, 384);

      // 表面填充：{0, 384, 393, 416}，颜色是 canvas.surface。
      final List<Object?> surface = _ops(c, 'fill')
          .firstWhere((List<Object?> command) => command[2] == 0 && command[5] == 416);
      expect(surface[3], 384, reason: 'sheetTop');
      expect(surface[4], 393, reason: '铺满页宽');
      expect(surface[1], c.surface);

      // 顶沿 1 高分隔线：{20, 384, 353, 1}。
      final List<Object?> line = _ops(c, 'fill')
          .firstWhere((List<Object?> command) => command[5] == 1);
      expect(line[2], 20);
      expect(line[3], 384);
      expect(line[4], 393 - 40);
      expect(line[1], c.line);

      // 标题「歌曲操作」落在 sheetTop + 18。
      final List<Object?> title = _ops(c, 'text').first;
      expect(title[1], '歌曲操作');
      expect(title[2], 20);
      expect(title[3], 384 + 18);
      expect(title[4], 18);

      // 只画 sheet：不铺整页纸色，也不自己 finish。
      expect(_ops(c, 'fill').any((List<Object?> command) => command[5] == 800), isFalse);
      expect(_ops(c, 'restore'), isNotEmpty, reason: 'beginContent 的 clip 已成对收回');
    });

    test('短屏不把 sheet 顶到 118 以上（Qt 的 max(118., …) 地板）', () {
      final PortraitCanvas c = _canvas(height: 500);
      final double sheetHeight = _paint(c);
      expect(c.height - sheetHeight, 118);
      expect(sheetHeight, 382);
    });

    test('sheet 打开时清掉 seek / volume 字段（Qt :237-238）', () {
      final PortraitCanvas c = _canvas();
      c.fields['seek'] = const Rect.fromLTWH(0, 0, 10, 10);
      c.fields['volume'] = const Rect.fromLTWH(0, 0, 10, 10);
      _paint(c);
      expect(c.fields.containsKey('seek'), isFalse);
      expect(c.fields.containsKey('volume'), isFalse);
    });

    test('宽页（586 网格）两列按页宽等分，右缘仍是页宽 - 20', () {
      final PortraitCanvas c = _canvas(gridWidth: 586);
      _paint(c);
      final HudHit second = c.hits.firstWhere((HudHit hit) => hit.action == 'music:comments');
      // 586 - 40 = 546 内宽，两列各 (546-9)/2 = 268.5，第二列起点 20 + 277.5。
      expect(second.x, closeTo(20 + 268.5 + 9, .001));
      expect(second.width, closeTo(268.5, .001));
      expect(second.x + second.width, closeTo(586 - 20, .001));
    });
  });

  group('按钮网格与命中串（:272-276）', () {
    test('i=0/1/2 两列排布：x = 20 / 201 / 20，y = 440 / 440 / 492，172×44', () {
      final PortraitCanvas c = _canvas();
      _paint(c);
      for (final String action in <String>['music:official', 'music:comments', 'music:playlist-add']) {
        expect(_hits(c, action), hasLength(1));
      }
      final HudHit hit0 = _hits(c, 'music:official').single;
      final HudHit hit1 = _hits(c, 'music:comments').single;
      final HudHit hit2 = _hits(c, 'music:playlist-add').single;
      // 384 + 56 = 440 是网格首行；第二行 +52。
      expect(hit0.x, 20);
      expect(hit0.y, 440);
      expect(hit0.width, 172);
      expect(hit0.height, 44);
      expect(hit1.x, 201, reason: '20 + 172 + 9 间隔');
      expect(hit1.y, 440);
      expect(hit2.x, 20, reason: 'i=2 回到第一列');
      expect(hit2.y, 492, reason: 'i=2 进第二行');
      // 命中串原样发出，命中标签是按钮 label。
      expect(hit0.action, 'music:official');
      expect(hit0.label, '官方客户端 ↗');
      expect(hit1.label, '查看评论');
    });

    test('按钮标签进命令流；空 action 只画按钮（不发射热区）', () {
      final PortraitCanvas c = _canvas();
      _paint(c, actions: const <(String label, String action)>[('不可用', ''), ('可用', 'music:x')]);
      expect(_texts(c), contains('不可用'));
      expect(_texts(c), contains('可用'));
      expect(c.hits.where((HudHit hit) => hit.action.isEmpty), isEmpty);
      expect(_hits(c, 'music:x'), hasLength(1));
    });
  });

  group('元信息行与说明段落（:275-276）', () {
    test('detail（专辑 / 时长）进命令流，落在网格下 12 处、12 号 muted', () {
      final PortraitCanvas c = _canvas();
      _paint(c);
      final List<Object?> meta = _ops(c, 'text')
          .firstWhere((List<Object?> command) => command[1] == 'Kernel Overflow / 04:21');
      // 384 + 56 + 2 行 × 52 + 12 = 556：三个按钮排两行，`y += ((size+1)/2)*52 + 12`。
      expect(meta[3], 556);
      expect(meta[4], 12);
      expect(meta[7], c.muted);

      // 空 detail 不画（不出现孤立的分隔符行）。
      final PortraitCanvas empty = _canvas();
      _paint(empty, detail: '');
      expect(_texts(empty), isNot(contains(' / ')));
    });

    test('说明段落从元信息行 + 25 起，最多 4 行、行距 18', () {
      final PortraitCanvas c = _canvas(metrics: _chunkedMetrics);
      _paint(c, detailBody: '本地曲目缺少官方播放地址，仅能从本机文件播放，评论仅对在线曲目开放，其余操作照常可用。');
      final List<List<Object?>> body = _bodyLines(c);
      // 43 字 / 每行 12 字 = 4 行，正好撞上上限，不截断也不补省略号。
      expect(body.length, 4);
      expect(body.first[3], 556 + 25);
      expect(body.first[4], 12);
      expect(body.first[7], c.muted);
      // 行距 12 × 1.5 = 18。
      expect(body[1][3], 556 + 25 + 18);

      // 超过 4 行才截断：最后一行补省略号，第 5 行不画。
      final PortraitCanvas over = _canvas(metrics: _chunkedMetrics);
      _paint(over, detailBody: '本地曲目缺少官方播放地址，仅能从本机文件播放，评论仅对在线曲目开放，其余操作照常可用，另有说明留给第五行。');
      final List<List<Object?>> cut = _bodyLines(over);
      expect(cut.length, 4);
      expect(cut.last[1], endsWith('…'));
    });

    test('scrollOffset 把网格与说明整体上移，夹在溢出量内，标题不动', () {
      final PortraitCanvas c = _canvas(height: 520);
      _paint(c, scrollOffset: 30);
      final HudHit hit0 = _hits(c, 'music:official').single;
      // 短屏 sheetTop = 118，网格首行 174；上移 30 → 144。
      expect(hit0.y, 118 + 56 + 30 - 30);
      // 标题与分隔线不随滚动偏移。
      final List<Object?> title = _ops(c, 'text').first;
      expect(title[3], 118 + 18);
      final List<Object?> line = _ops(c, 'fill').firstWhere((List<Object?> command) => command[5] == 1);
      expect(line[3], 118);

      // 超出部分的上限：没有溢出时传 100 也只按 0 处理。
      final PortraitCanvas tall = _canvas();
      _paint(tall, scrollOffset: 100);
      final HudHit top = _hits(tall, 'music:official').single;
      expect(top.y, 384 + 56);
    });
  });
}
