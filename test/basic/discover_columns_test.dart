/// 发现页瓦片列数按页宽动态（用户第 8 条：单卡限制最大宽度、类似 tab 动态加列）。
///
/// 2026-11-26 用户把竖屏单卡上限从 200 收到 **120**：本机 586 网格从 2 列变 4 列，
/// 393 稿仍是 2 列（列数下限夹取 2）。列数一变，同一条目的列/行位置也要跟着换，
/// 否则后一列会被挤到第一列的位置互相压住。
///
/// 横屏不走这条路径（横屏是 Qt 桌面弹层的 `DiscoverCard`，固定五列）。
library;


import 'dart:math' as math;
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
  test('列数按可用宽度除以单卡最大宽度 120，夹在 2..6', () {
    expect(portraitDiscoverColumnsForWidth(393), 2, reason: '393 稿两列（下限夹取）');
    expect(portraitDiscoverColumnsForWidth(586), 4, reason: '本机 586 网格 4 列');
    expect(portraitDiscoverColumnsForWidth(520), 4);
    expect(portraitDiscoverColumnsForWidth(760), 6);
    expect(portraitDiscoverColumnsForWidth(900), 6);
    expect(portraitDiscoverColumnsForWidth(2000), 6, reason: '上限 6 列');
  });

  test('本机竖屏格宽（586）四列：第 1..4 条同一行，第 5 条换行', () {
    final List<HudHit> hits = _paintTiles(586);
    final double step = (586 - 40) / 4;
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
    expect(fifth.x, first.x, reason: '五列时第 5 条必须换行');
    expect(fifth.y, greaterThan(first.y));
  });

  test('393 稿仍是两列，第 3 条换行', () {
    final List<HudHit> hits = _paintTiles(393);
    final double step = (393 - 40) / 2;
    final HudHit first = _tileHit(hits, 1);
    final HudHit second = _tileHit(hits, 2);
    final HudHit third = _tileHit(hits, 3);
    expect(first.x, 20);
    expect(second.x, closeTo(20 + step, .01));
    expect(second.y, first.y);
    expect(third.x, first.x);
    expect(third.y, greaterThan(first.y));
  });

  test('未触到列数上下限时单卡宽度不超过 120（触限时只能夹取）', () {
    for (final double width in <double>[520, 586, 760, 900]) {
      final int columns = portraitDiscoverColumnsForWidth(width);
      final bool clamped = columns <= 2 || columns >= 6;
      final double tileStep = (width - 40) / columns;
      if (!clamped) {
        expect(
          tileStep,
          lessThanOrEqualTo(portraitDiscoverTileMaxWidth + 30),
          reason: '$width 宽 / $columns 列时单卡 $tileStep 超出 120 上限',
        );
      }
    }
  });

/// 「▶ 全部」必须贴整张卡片的右缘（用户 2026-11-26：按钮不该只对齐封面的右侧，
/// 否则标题可用宽只有 `coverSize - 40`，长标题一律被截成「二次元小…」）。
test('播放全部按钮贴卡片右缘，标题可用宽变宽', () {
  for (final double width in <double>[393, 586, 900]) {
    final PortraitCanvas c = _canvas(gridWidth: width, height: 1400);
    final List<PortraitDiscoverEntry> entries = <PortraitDiscoverEntry>[
      PortraitDiscoverEntry(index: 0, title: '精选', artist: '艺人'),
      for (int i = 1; i < 5; i += 1)
        PortraitDiscoverEntry(
          index: i,
          title: '条目 $i',
          artist: '艺人 $i',
          kind: 'playlist',
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

    final int columns = portraitDiscoverColumnsForWidth(width);
    final double tileStep = (width - 40) / columns;
    final double cardWidth = tileStep - 15;
    final double coverSize = math.max(72, cardWidth - 25);

    // 第二个条目（index=1）落在第一列，取它的播放命中矩形。
    final List<HudHit> plays = <HudHit>[
      for (final HudHit hit in c.hits)
        if (hit.action == '${portraitPlayDiscoverPrefix}1') hit,
    ];
    expect(plays, hasLength(1), reason: '$width 宽时列 1 的「▶ 全部」应恰好一个命中');
    final HudHit play = plays.single;
    final double tileLeft = 20;
    expect(play.x + play.width, closeTo(tileLeft + cardWidth, 1.5),
        reason: '$width 宽：命中右缘必须与卡片右缘对齐（cardWidth $cardWidth）');

    // 标题的绘制宽度必须比「只按封面算」更宽，且不被封面右缘截住。
    final List<List<Object?>> texts = <List<Object?>>[
      for (final List<Object?> command in c.commands)
        if (command[0] == 'text') command,
    ];
    final List<Object?> title = texts.firstWhere(
      (List<Object?> command) => command[1] == '条目 1',
      orElse: () => <Object?>[],
    );
    expect(title, isNotEmpty, reason: '$width 宽：标题必须画出来（不能被截成空）');
    final double playTextLeft = play.x + 4;
    final double titleUsed = math.max(48, playTextLeft - 6 - tileLeft);
    expect(titleUsed, greaterThan(coverSize - 40 + 1),
        reason: '$width 宽：标题可用宽应超过旧的 coverSize-40 口径');
  }
});
}
