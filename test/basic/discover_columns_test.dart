/// 发现页瓦片列数按页宽动态（用户第 8 条：单卡限制最大宽度、类似 tab 动态加列）。
///
/// 393 设计稿与 586 的 DPI 放大竖屏都是两列；只有更宽的舞台（平板 / 复用同一页
/// 的横屏面板）才加列，上限 6 列。列数一变，同一条目的列/行位置也要跟着换，
/// 否则第三列会被挤到第一列的位置互相压住。
library;


import 'package:flutter_test/flutter_test.dart';
import 'package:rhine_music_database/hud/portrait/portrait_canvas.dart';
import 'package:rhine_music_database/hud/portrait/portrait_discover_page.dart';
import 'package:rhine_music_database/hud/protocol/hud_hit.dart';

PortraitCanvas _canvas({required double gridWidth, required double height}) =>
    PortraitCanvas(
      metrics: PortraitMetrics(
        width: (String value, double size, String weight) =>
            value.length * size * .6,
        wrap: (String value, double limit, double size, String weight) =>
            <String>[value],
        bounds: (String value, double size, String weight) =>
            PortraitGlyphBounds(width: value.length * size * .6, height: size),
      ),
      unit: 1,
      gridWidth: gridWidth,
      height: height,
      dark: true,
    )..contentBottom = height - 144;

List<HudHit> _paintTiles(double gridWidth) {
  final PortraitCanvas c = _canvas(gridWidth: gridWidth, height: 1400);
  final List<PortraitDiscoverEntry> entries = <PortraitDiscoverEntry>[
    for (int i = 0; i < 13; i += 1)
      PortraitDiscoverEntry(
        index: i,
        title: '条目 $i',
        artist: '艺人 $i',
      ),
  ];
  paintPortraitDiscoverPage(
    c,
    tabs: const <PortraitDiscoverChip>[
      PortraitDiscoverChip(
        label: '推荐歌单',
        action: '${portraitDiscoverTabPrefix}playlists',
        selected: true,
      ),
    ],
    tab: 'playlists',
    entries: entries,
  );
  return <HudHit>[
    for (final HudHit hit in c.hits)
      if (hit.action.startsWith(portraitDiscoverItemPrefix)) hit,
  ];
}

HudHit _tileHit(List<HudHit> hits, int index) => hits.firstWhere(
  (HudHit hit) => hit.action == '$portraitDiscoverItemPrefix$index',
);

void main() {
  test('列数按可用宽度除以单卡最大宽度，夹在 2..6', () {
    expect(portraitDiscoverColumnsForWidth(393), 2);
    expect(portraitDiscoverColumnsForWidth(586), 2);
    expect(portraitDiscoverColumnsForWidth(760), 3);
    expect(portraitDiscoverColumnsForWidth(900), 4);
    expect(portraitDiscoverColumnsForWidth(1080), 5);
    expect(portraitDiscoverColumnsForWidth(1280), 6);
    expect(portraitDiscoverColumnsForWidth(2000), 6);
  });

  test('四列页宽下第 3、4 条与第 1 条同一行，第 5 条落到下一行', () {
    final List<HudHit> hits = _paintTiles(900);
    final double step = (900 - 40) / 4;
    final HudHit first = _tileHit(hits, 1);
    final HudHit second = _tileHit(hits, 2);
    final HudHit third = _tileHit(hits, 3);
    final HudHit fourth = _tileHit(hits, 4);
    final HudHit fifth = _tileHit(hits, 5);
    expect(first.x, 20);
    expect(second.x, closeTo(20 + step, .01));
    expect(third.x, closeTo(20 + step * 2, .01));
    expect(fourth.x, closeTo(20 + step * 3, .01));
    expect(fourth.y, first.y);
    expect(fifth.x, first.x);
    expect(fifth.y, greaterThan(first.y));
  });

  test('本机竖屏格宽（586）仍是两列，与参考稿一致', () {
    final List<HudHit> hits = _paintTiles(586);
    final double step = (586 - 40) / 2;
    final HudHit first = _tileHit(hits, 1);
    final HudHit second = _tileHit(hits, 2);
    final HudHit third = _tileHit(hits, 3);
    expect(first.x, 20);
    expect(second.x, closeTo(20 + step, .01));
    expect(second.y, first.y);
    expect(third.x, first.x, reason: '两列时第 3 条必须换行');
    expect(third.y, greaterThan(first.y));
  });

  test('单卡宽度不超过上限（列再多封面也不会被拉成巨幅）', () {
    for (final double width in <double>[900, 1080, 1280]) {
      final int columns = portraitDiscoverColumnsForWidth(width);
      final double cardWidth = (width - 40) / columns - 15;
      expect(cardWidth, lessThanOrEqualTo(portraitDiscoverTileMaxWidth + 40));
    }
  });
}
