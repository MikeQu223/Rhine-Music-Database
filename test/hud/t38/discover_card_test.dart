// Written but NOT executed: the writer task forbids running flutter/dart test,
// analyze or build. Intended command:
//   flutter test test/hud/t38/discover_card_test.dart
//
// Every expected number below is copied from, or computed exactly as, the Qt
// source cited next to it; none is read back from the Dart implementation.
//
// Qt evidence used throughout:
//   Qt/src/DiscoverMusicCard.cpp:5-15    layout
//   Qt/src/DiscoverMusicCard.cpp:17-31   entryBounds
//   Qt/src/DiscoverMusicCard.cpp:34-52   visibleIndices
//   Qt/src/DiscoverMusicCard.cpp:56-380  Painter
//   Qt/src/NativeHudChecks.cpp:1159-1331 five columns / no overlap / hit clipped
//                                        to viewport / rotation / centred tab /
//                                        cover aspect / 40-item category paging

import 'dart:math' as math;
import 'dart:ui' show Rect;

import 'package:flutter_test/flutter_test.dart';
import 'package:rhine_music_database/hud/widgets/discover_card.dart';

const double _epsilon = 1e-9;

/// Deterministic stand-in for Qt Glyphs::width: one UTF-16 code unit is
/// 0.6 * size wide. The card must never hardcode glyph widths, so tests inject
/// this and only ever assert geometry derived from it.
double _measure(String value, double size) => value.length * size * 0.6;

/// Qt/src/NativeHud.cpp:10-15 + Qt/src/DiscoverMusicCard.cpp:95-101.
const List<double> _lightPaper = <double>[0.973, 0.969, 0.933, 1];
const List<double> _lightInk = <double>[0.133, 0.165, 0.145, 1];
const List<double> _lightMuted = <double>[0.39, 0.43, 0.38, 1];
const List<double> _lightSoft = <double>[0.89, 0.90, 0.85, 1];
const List<double> _darkPaper = <double>[0.09, 0.115, 0.095, 1];
const List<double> _darkInk = <double>[0.93, 0.94, 0.88, 1];
const List<double> _darkMuted = <double>[0.65, 0.69, 0.62, 1];
const List<double> _darkSoft = <double>[0.16, 0.20, 0.16, 1];
const List<double> _amber = <double>[0.835, 0.639, 0.282, 1];
const List<double> _night = <double>[0.133, 0.165, 0.145, 1];
const List<double> _white = <double>[0.95, 0.95, 0.9, 1];

class _FillRecord {
  const _FillRecord(this.x, this.y, this.width, this.height, this.color);
  final double x;
  final double y;
  final double width;
  final double height;
  final List<double> color;
}

class _TextRecord {
  const _TextRecord(this.value, this.x, this.y, this.size, this.weight, this.color);
  final String value;
  final double x;
  final double y;
  final double size;
  final String weight;
  final List<double> color;
}

class _HitRecord {
  const _HitRecord(this.x, this.y, this.width, this.height, this.action, this.label);
  final double x;
  final double y;
  final double width;
  final double height;
  final String action;
  final String label;
}

class _ImageRecord {
  const _ImageRecord(this.key, this.x, this.y, this.width, this.height);
  final String key;
  final double x;
  final double y;
  final double width;
  final double height;
}

class _CircleRecord {
  const _CircleRecord(this.cx, this.cy, this.radius, this.color);
  final double cx;
  final double cy;
  final double radius;
  final List<double> color;
}

/// Records every Canvas callback in call order; never applies the recorded
/// transform commands (the card is expected to emit untransformed geometry plus
/// explicit save/clip/translate/restore, exactly like Qt).
class _Recorder implements DiscoverCanvas {
  final List<_FillRecord> fills = <_FillRecord>[];
  final List<_TextRecord> texts = <_TextRecord>[];
  final List<_HitRecord> hits = <_HitRecord>[];
  final List<_ImageRecord> images = <_ImageRecord>[];
  final List<_CircleRecord> circles = <_CircleRecord>[];
  final List<List<Object?>> commands = <List<Object?>>[];

  @override
  void fill(double x, double y, double width, double height, List<double> color) {
    fills.add(_FillRecord(x, y, width, height, List<double>.of(color)));
  }

  @override
  void text(String value, double x, double y, double size, String weight, List<double> color) {
    texts.add(_TextRecord(value, x, y, size, weight, List<double>.of(color)));
  }

  @override
  String fit(String value, double size, double available, String weight) {
    if (measure(value, size, weight) <= available) {
      return value;
    }
    String result = value;
    while (result.isNotEmpty && measure('$result…', size, weight) > available) {
      result = result.substring(0, result.length - 1);
    }
    return result.isEmpty ? '…' : '$result…';
  }

  @override
  List<String> wrap(String value, double width, double size, String weight) {
    final List<String> lines = <String>[];
    final List<String> words = value.split(' ');
    String current = '';
    for (final String word in words) {
      final String candidate = current.isEmpty ? word : '$current $word';
      if (current.isNotEmpty && measure(candidate, size, weight) > width) {
        lines.add(current);
        current = word;
      } else {
        current = candidate;
      }
    }
    if (current.isNotEmpty) {
      lines.add(current);
    }
    return lines;
  }

  @override
  void hit(double x, double y, double width, double height, String action, String label) {
    hits.add(_HitRecord(x, y, width, height, action, label));
  }

  @override
  void image(String key, double x, double y, double width, double height) {
    images.add(_ImageRecord(key, x, y, width, height));
  }

  @override
  void circle(double cx, double cy, double radius, List<double> color) {
    circles.add(_CircleRecord(cx, cy, radius, List<double>.of(color)));
  }

  @override
  double measure(String value, double size, String weight) => _measure(value, size);

  @override
  void command(List<Object?> command) {
    commands.add(List<Object?>.of(command));
  }
}

bool _eq(double a, double b) => (a - b).abs() < 1e-9;

/// Qt/src/NativeHud.cpp:153-158: modalWidth = min(1260, stage - 100), centred,
/// top 122, height 836 (Qt/src/NativeHudDiscover.cpp:13).
Rect _stageBounds(int stage) {
  final double modalWidth = math.min(1260.0, stage - 100.0);
  return Rect.fromLTWH((stage - modalWidth) / 2, 122, modalWidth, 836);
}

List<DiscoverChoice> _tabs({int selected = 0}) => <DiscoverChoice>[
      DiscoverChoice(label: '推荐歌单', action: 'discover:tab:playlists', selected: selected == 0),
      DiscoverChoice(label: '每日推荐', action: 'discover:tab:daily', selected: selected == 1),
      DiscoverChoice(label: '排行榜', action: 'discover:tab:charts', selected: selected == 2),
      DiscoverChoice(label: '专辑', action: 'discover:tab:albums', selected: selected == 3),
      DiscoverChoice(label: '分类', action: 'discover:tab:categories', selected: selected == 4),
    ];

DiscoverEntry _entry(int index, {String kind = 'playlist', String image = '', double imageAspect = 1}) =>
    DiscoverEntry(
      title: 'Archive $index',
      artist: 'Artist $index',
      kind: kind,
      image: image,
      imageAspect: imageAspect,
      index: index,
    );

DiscoverModel _model({
  Rect? bounds,
  bool dark = false,
  List<DiscoverChoice>? tabs,
  List<DiscoverChoice>? tools,
  List<DiscoverChoice>? categories,
  List<DiscoverEntry>? entries,
  double scroll = 0,
  bool loading = false,
  bool more = false,
  bool categoryPicker = false,
  int categoryPage = 0,
  int categoryPages = 1,
  String status = '',
  int loadedCount = 0,
}) =>
    DiscoverModel(
      bounds: bounds ?? _stageBounds(1920),
      dark: dark,
      tab: 'playlists',
      status: status,
      loading: loading,
      more: more,
      tabs: tabs ?? _tabs(),
      tools: tools ?? <DiscoverChoice>[],
      categories: categories ?? <DiscoverChoice>[],
      entries: entries ?? <DiscoverEntry>[],
      scroll: scroll,
      categoryPicker: categoryPicker,
      categoryPage: categoryPage,
      categoryPages: categoryPages,
      loadedCount: loadedCount,
    );

_Recorder _paint(DiscoverModel model) {
  final _Recorder recorder = _Recorder();
  DiscoverCard.paint(model, recorder);
  return recorder;
}

List<_FillRecord> _fillsAt(_Recorder recorder, double x, double y) =>
    recorder.fills.where((_FillRecord fill) => _eq(fill.x, x) && _eq(fill.y, y)).toList();

_FillRecord _onlyFillAt(_Recorder recorder, double x, double y) {
  final List<_FillRecord> matches = _fillsAt(recorder, x, y);
  expect(matches.length, 1, reason: 'expected exactly one fill at $x,$y');
  return matches.single;
}

_TextRecord _text(_Recorder recorder, String value) => recorder.texts
    .firstWhere((_TextRecord record) => record.value == value, orElse: () => throw StateError('missing text $value'));

_HitRecord _hitAction(_Recorder recorder, String action) => recorder.hits
    .firstWhere((_HitRecord record) => record.action == action, orElse: () => throw StateError('missing hit $action'));

List<_HitRecord> _itemHits(_Recorder recorder) =>
    recorder.hits.where((_HitRecord record) => record.action.startsWith('discover:item:')).toList();

void main() {
  group('constants match Qt/src/DiscoverMusicCard.h:51-53', () {
    test('five archive columns, viewport 230..748, panel height 836', () {
      expect(DiscoverCard.archiveColumnCount, 5);
      expect(DiscoverCard.viewportTop, 230.0);
      expect(DiscoverCard.viewportBottom, 748.0);
      expect(discoverPanelHeight, 836.0);
      expect(discoverFramedRotation, 0.0872664626);
    });
  });

  group('layout: Qt/src/DiscoverMusicCard.cpp:5-15', () {
    test('1920 stage: viewport (383,352,1154,518), tile 216.4, stride 328.4', () {
      final DiscoverLayout geometry = DiscoverCard.layout(_stageBounds(1920), 12);
      expect(geometry.viewport.left, closeTo(383.0, _epsilon));
      expect(geometry.viewport.top, closeTo(352.0, _epsilon));
      expect(geometry.viewport.width, closeTo(1154.0, _epsilon));
      expect(geometry.viewport.height, closeTo(518.0, _epsilon));
      // (1154 - 4 * 18) / 5 = 1082 / 5.
      expect(geometry.tileSize, closeTo(216.4, _epsilon));
      expect(geometry.rowStride, closeTo(328.4, _epsilon));
    });

    test('1280 stage: modal 1180 wide at left 50, tile 200.4, stride 312.4', () {
      final DiscoverLayout geometry = DiscoverCard.layout(_stageBounds(1280), 12);
      expect(geometry.viewport.left, closeTo(103.0, _epsilon));
      expect(geometry.viewport.width, closeTo(1074.0, _epsilon));
      // (1074 - 72) / 5 = 1002 / 5.
      expect(geometry.tileSize, closeTo(200.4, _epsilon));
      expect(geometry.rowStride, closeTo(312.4, _epsilon));
    });

    test('2560 stage keeps the 1260 modal, so tile stays 216.4 at left 703', () {
      final DiscoverLayout geometry = DiscoverCard.layout(_stageBounds(2560), 12);
      expect(geometry.viewport.left, closeTo(703.0, _epsilon));
      expect(geometry.tileSize, closeTo(216.4, _epsilon));
      expect(geometry.rowStride, closeTo(328.4, _epsilon));
    });

    test('rows use C++ integer division: count 0/1/2 give no scroll', () {
      final Rect bounds = _stageBounds(1920);
      expect(DiscoverCard.layout(bounds, 0).maximumScroll, 0.0);
      expect(DiscoverCard.layout(bounds, 1).maximumScroll, 0.0);
      expect(DiscoverCard.layout(bounds, 2).maximumScroll, 0.0);
    });

    test('count 7 -> one row, bottom 836.4, maximumScroll 88.4', () {
      // rows = (max(0, 5) + 4) / 5 = 1; bottom = 526 + 328.4 - 18.
      final DiscoverLayout geometry = DiscoverCard.layout(_stageBounds(1920), 7);
      expect(geometry.maximumScroll, closeTo(88.4, _epsilon));
    });

    test('count 12 -> two rows, bottom 1164.8, maximumScroll 416.8', () {
      // rows = (10 + 4) / 5 = 2; bottom = 526 + 2 * 328.4 - 18.
      final DiscoverLayout geometry = DiscoverCard.layout(_stageBounds(1920), 12);
      expect(geometry.maximumScroll, closeTo(416.8, _epsilon));
    });

    test('count 13 -> three rows, maximumScroll 745.2 (ceil semantics)', () {
      // rows = (11 + 4) / 5 = 3; bottom = 526 + 3 * 328.4 - 18.
      final DiscoverLayout geometry = DiscoverCard.layout(_stageBounds(1920), 13);
      expect(geometry.maximumScroll, closeTo(745.2, _epsilon));
    });

    test('layout is purely bounds-relative', () {
      final DiscoverLayout shifted = DiscoverCard.layout(Rect.fromLTWH(430, 222, 1260, 836), 12);
      expect(shifted.viewport.left, closeTo(483.0, _epsilon));
      expect(shifted.viewport.top, closeTo(452.0, _epsilon));
      expect(shifted.tileSize, closeTo(216.4, _epsilon));
      expect(shifted.maximumScroll, closeTo(416.8, _epsilon));
    });
  });

  group('entryBounds: Qt/src/DiscoverMusicCard.cpp:17-31', () {
    final Rect bounds = _stageBounds(1920);

    test('index 0 is the featured card: (383,352,749.76,238)', () {
      final Rect rect = DiscoverCard.entryBounds(bounds, 0);
      // featuredWidth = (1154 - 18) * 0.66 = 749.76.
      expect(rect.left, closeTo(383.0, _epsilon));
      expect(rect.top, closeTo(352.0, _epsilon));
      expect(rect.width, closeTo(749.76, _epsilon));
      expect(rect.height, closeTo(238.0, _epsilon));
    });

    test('index 1 is the secondary card, 18 to the right of the featured card', () {
      final Rect first = DiscoverCard.entryBounds(bounds, 0);
      final Rect second = DiscoverCard.entryBounds(bounds, 1);
      expect(second.left, closeTo(1150.76, _epsilon));
      expect(second.top, closeTo(352.0, _epsilon));
      expect(second.width, closeTo(386.24, _epsilon));
      expect(second.height, closeTo(238.0, _epsilon));
      expect(second.left - first.right, closeTo(18.0, _epsilon));
      expect(second.right, closeTo(1537.0, _epsilon));
    });

    test('index 2 starts the square archive grid at (383,648) tile 216.4 x 310.4', () {
      final Rect rect = DiscoverCard.entryBounds(bounds, 2);
      expect(rect.left, closeTo(383.0, _epsilon));
      expect(rect.top, closeTo(648.0, _epsilon));
      expect(rect.width, closeTo(216.4, _epsilon));
      // rowStride - 18 = 328.4 - 18.
      expect(rect.height, closeTo(310.4, _epsilon));
    });

    test('five columns share one row: same y, 234.4 pitch, 18 gutter', () {
      final List<Rect> row = <Rect>[
        for (int index = 2; index < 7; index++) DiscoverCard.entryBounds(bounds, index),
      ];
      for (final Rect rect in row) {
        expect(rect.top, closeTo(648.0, _epsilon));
        expect(rect.width, closeTo(216.4, _epsilon));
      }
      for (int index = 1; index < row.length; index++) {
        expect(row[index].left - row[index - 1].left, closeTo(234.4, _epsilon));
        expect(row[index].left - row[index - 1].right, closeTo(18.0, _epsilon));
      }
      expect(row.last.right, closeTo(1537.0, _epsilon));
    });

    test('index 7 wraps to the second row: y 976.4, x back to 383', () {
      final Rect rect = DiscoverCard.entryBounds(bounds, 7);
      expect(rect.left, closeTo(383.0, _epsilon));
      expect(rect.top, closeTo(976.4, _epsilon));
    });
  });

  group('visibleIndices: Qt/src/DiscoverMusicCard.cpp:34-52', () {
    final Rect bounds = _stageBounds(1920);

    test('no entries -> empty list', () {
      expect(DiscoverCard.visibleIndices(bounds, 0, 0), <int>[]);
    });

    test('count 1 only shows the featured card', () {
      expect(DiscoverCard.visibleIndices(bounds, 1, 0), <int>[0]);
    });

    test('count 2 shows both special cards and no tiles', () {
      expect(DiscoverCard.visibleIndices(bounds, 2, 0), <int>[0, 1]);
    });

    test('count 12 at scroll 0: both special cards plus the first five tiles', () {
      // firstRow = int((230 - 526) / 328.4) -> 0 (truncated toward zero),
      // lastRow = int((748 - 526) / 328.4) -> 0.
      expect(DiscoverCard.visibleIndices(bounds, 12, 0), <int>[0, 1, 2, 3, 4, 5, 6]);
    });

    test('count 12 at maximumScroll: special cards leave, all ten tiles stay', () {
      final double maximum = DiscoverCard.layout(bounds, 12).maximumScroll;
      // 352 - 416.8 = -64.8..173.2 no longer reaches the 352..870 viewport.
      expect(DiscoverCard.visibleIndices(bounds, 12, maximum), <int>[2, 3, 4, 5, 6, 7, 8, 9, 10, 11]);
    });

    test('scroll is clamped into 0..maximumScroll', () {
      final double maximum = DiscoverCard.layout(bounds, 12).maximumScroll;
      expect(DiscoverCard.visibleIndices(bounds, 12, 9999), DiscoverCard.visibleIndices(bounds, 12, maximum));
      expect(DiscoverCard.visibleIndices(bounds, 12, -50), DiscoverCard.visibleIndices(bounds, 12, 0));
    });

    test('a partially visible tile is still visible (Qt QRectF::intersects)', () {
      // At scroll 0 row 0 is cut at the viewport bottom (870) yet present.
      expect(DiscoverCard.visibleIndices(bounds, 12, 0).contains(2), isTrue);
    });

    test('count 7 at maximumScroll keeps the special cards partially visible', () {
      final double maximum = DiscoverCard.layout(bounds, 7).maximumScroll;
      // 352 - 88.4 = 263.6..501.6 still crosses the 352 top edge.
      expect(DiscoverCard.visibleIndices(bounds, 7, maximum), <int>[0, 1, 2, 3, 4, 5, 6]);
    });
  });

  group('paint: panel chrome (Qt/src/DiscoverMusicCard.cpp:67-166)', () {
    test('paper covers the whole panel, then a 3px ink top rule', () {
      final _Recorder recorder = _paint(_model());
      expect(recorder.fills[0].x, closeTo(330.0, _epsilon));
      expect(recorder.fills[0].y, closeTo(122.0, _epsilon));
      expect(recorder.fills[0].width, closeTo(1260.0, _epsilon));
      expect(recorder.fills[0].height, closeTo(836.0, _epsilon));
      expect(recorder.fills[0].color, _lightPaper);
      expect(recorder.fills[1].width, closeTo(1260.0, _epsilon));
      expect(recorder.fills[1].height, closeTo(3.0, _epsilon));
      expect(recorder.fills[1].color, _lightInk);
    });

    test('dark theme swaps only paper/ink/muted/soft', () {
      final _Recorder recorder = _paint(_model(dark: true));
      expect(recorder.fills[0].color, _darkPaper);
      expect(recorder.fills[1].color, _darkInk);
      expect(_text(recorder, '02 / MUSIC DIRECTORY').color, _darkMuted);
    });

    test('header copy sits on the Qt coordinates (x=383, y=bounds.y+25/65/76/97)', () {
      final _Recorder recorder = _paint(_model());
      final _TextRecord directory = _text(recorder, '02 / MUSIC DIRECTORY');
      expect(directory.x, closeTo(383.0, _epsilon));
      expect(directory.y, closeTo(147.0, _epsilon));
      expect(directory.size, 11.0);
      expect(directory.color, _lightMuted);
      final _TextRecord title = _text(recorder, '发现音乐');
      expect(title.x, closeTo(383.0, _epsilon));
      expect(title.y, closeTo(187.0, _epsilon));
      expect(title.size, 36.0);
      expect(title.weight, 'bold');
      final _TextRecord latin = _text(recorder, 'Discover music');
      expect(latin.x, closeTo(573.0, _epsilon));
      expect(latin.y, closeTo(198.0, _epsilon));
      expect(latin.size, 22.0);
      expect(latin.weight, 'light');
      final _TextRecord lab = _text(recorder, 'RHINE LAB / MUSIC DATABASE');
      expect(lab.x, closeTo(1267.0, _epsilon));
      expect(lab.y, closeTo(219.0, _epsilon));
      expect(lab.size, 10.0);
    });

    test('close button: 140x38 at (1397,142) with a 1px 0.18-alpha border', () {
      final _Recorder recorder = _paint(_model());
      final _HitRecord hit = _hitAction(recorder, 'close-modal');
      expect(hit.x, closeTo(1397.0, _epsilon));
      expect(hit.y, closeTo(142.0, _epsilon));
      expect(hit.width, closeTo(140.0, _epsilon));
      expect(hit.height, closeTo(38.0, _epsilon));
      expect(hit.label, '← 返回');
      // The 1px top edge and the 1px left post share the corner (1397,142).
      final List<_FillRecord> corner = _fillsAt(recorder, 1397.0, 142.0);
      expect(corner.length, 2);
      final _FillRecord top = corner.firstWhere((_FillRecord fill) => _eq(fill.width, 140.0));
      expect(top.height, closeTo(1.0, _epsilon));
      expect(top.color, <double>[0.133, 0.165, 0.145, 0.18]);
      final _FillRecord leftPost = corner.firstWhere((_FillRecord fill) => _eq(fill.width, 1.0));
      expect(leftPost.height, closeTo(38.0, _epsilon));
      // Bottom edge at top + height - 1.
      expect(_onlyFillAt(recorder, 1397.0, 179.0).height, closeTo(1.0, _epsilon));
      // Right 1px post.
      expect(_onlyFillAt(recorder, 1536.0, 142.0).width, closeTo(1.0, _epsilon));
    });

    test('tabs: two rules at 126/170, 40-high hits at 128, text at 141', () {
      final _Recorder recorder = _paint(_model());
      expect(_onlyFillAt(recorder, 383.0, 248.0).width, closeTo(1154.0, _epsilon));
      expect(_onlyFillAt(recorder, 383.0, 292.0).width, closeTo(1154.0, _epsilon));
      final _HitRecord first = _hitAction(recorder, 'discover:tab:playlists');
      // cell = 1154 / 5 = 230.8.
      expect(first.x, closeTo(383.0, _epsilon));
      expect(first.y, closeTo(250.0, _epsilon));
      expect(first.width, closeTo(230.8, _epsilon));
      expect(first.height, closeTo(40.0, _epsilon));
      expect(_text(recorder, '推荐歌单').y, closeTo(263.0, _epsilon));
    });

    test('selected tab draws the amber underline min(48, cell - 8) at 169', () {
      final _Recorder recorder = _paint(_model());
      // cell - 8 = 222.8 > 48, so the underline is 48 wide, centred in the cell.
      final _FillRecord underline = _onlyFillAt(recorder, 383.0 + (230.8 - 48.0) / 2, 291.0);
      expect(underline.width, closeTo(48.0, _epsilon));
      expect(underline.height, closeTo(3.0, _epsilon));
      expect(underline.color, _amber);
      expect(recorder.fills.where((_FillRecord fill) => _eq(fill.height, 3.0) && _eq(fill.y, 291.0)).length, 1);
    });

    test('tab label is centred on its hit rect (NativeHudChecks.cpp tab centring)', () {
      final _Recorder recorder = _paint(_model());
      final _HitRecord hit = _hitAction(recorder, 'discover:tab:playlists');
      final _TextRecord text = _text(recorder, '推荐歌单');
      final double textCenter = text.x + _measure(text.value, text.size) / 2;
      final double hitCenter = hit.x + hit.width / 2;
      expect(textCenter, closeTo(hitCenter, 1e-6));
    });

    test('empty tools list draws the curated-archives caption at 191', () {
      final _Recorder recorder = _paint(_model());
      final _TextRecord caption = _text(recorder, 'CURATED ARCHIVES / 精选音乐档案');
      expect(caption.x, closeTo(383.0, _epsilon));
      expect(caption.y, closeTo(313.0, _epsilon));
      expect(caption.size, 10.0);
      expect(caption.color, _lightMuted);
    });

    test('tools: cell min(190, width/n), 32 high at 182, amber bar at 213', () {
      final _Recorder recorder = _paint(_model(tools: <DiscoverChoice>[
        DiscoverChoice(label: '换一批推荐 ↻', action: 'discover:guess', selected: true),
        DiscoverChoice(label: '在资料库打开 ↗', action: 'discover:open'),
      ]));
      final _HitRecord first = _hitAction(recorder, 'discover:guess');
      expect(first.x, closeTo(383.0, _epsilon));
      expect(first.y, closeTo(304.0, _epsilon));
      expect(first.width, closeTo(182.0, _epsilon));
      expect(first.height, closeTo(32.0, _epsilon));
      final _HitRecord second = _hitAction(recorder, 'discover:open');
      expect(second.x, closeTo(573.0, _epsilon));
      // The button's bottom border (1px) and the selected amber bar (2px) share y=335.
      final _FillRecord bar = recorder.fills
          .firstWhere((_FillRecord fill) => _eq(fill.x, 383.0) && _eq(fill.y, 335.0) && _eq(fill.height, 2.0));
      expect(bar.width, closeTo(182.0, _epsilon));
      expect(bar.height, closeTo(2.0, _epsilon));
      expect(bar.color, _amber);
    });
  });

  group('paint: empty / loading branch (Qt/src/DiscoverMusicCard.cpp:344-350)', () {
    test('empty branch: rule at 230, MUSIC ARCHIVE, 暂无内容, caption', () {
      final _Recorder recorder = _paint(_model());
      expect(_onlyFillAt(recorder, 383.0, 352.0).width, closeTo(1154.0, _epsilon));
      final _TextRecord heading = _text(recorder, 'MUSIC ARCHIVE');
      expect(heading.x, closeTo(383.0, _epsilon));
      expect(heading.y, closeTo(458.0, _epsilon));
      expect(heading.size, 12.0);
      expect(heading.color, _lightMuted);
      final _TextRecord body = _text(recorder, '暂无内容');
      expect(body.y, closeTo(499.0, _epsilon));
      expect(body.size, 25.0);
      expect(body.weight, 'demibold');
      final _TextRecord caption = _text(recorder, '切换上方分类，继续探索音乐资料库。');
      expect(caption.y, closeTo(550.0, _epsilon));
      expect(caption.size, 13.0);
      expect(caption.color, _lightMuted);
    });

    test('empty branch draws no recommendation header and no scroll indicator', () {
      final _Recorder recorder = _paint(_model());
      expect(recorder.texts.where((_TextRecord record) => record.value == '音乐档案'), isEmpty);
      expect(_fillsAt(recorder, 1553.0, 352.0), isEmpty);
      expect(_itemHits(recorder), isEmpty);
    });

    test('loading branch swaps both captions but keeps the same geometry', () {
      final _Recorder recorder = _paint(_model(loading: true, loadedCount: 0));
      final _TextRecord heading = _text(recorder, 'LOADING ARCHIVES');
      expect(heading.y, closeTo(458.0, _epsilon));
      expect(heading.size, 12.0);
      final _TextRecord body = _text(recorder, '正在读取音乐…');
      expect(body.y, closeTo(499.0, _epsilon));
      expect(body.size, 25.0);
      expect(body.weight, 'demibold');
      expect(recorder.texts.where((_TextRecord record) => record.value == '暂无内容'), isEmpty);
    });

    test('a non-empty status replaces 暂无内容 without touching the captions', () {
      final _Recorder recorder = _paint(_model(status: '网络不可用'));
      final _TextRecord body = _text(recorder, '网络不可用');
      expect(body.y, closeTo(499.0, _epsilon));
      expect(body.size, 25.0);
      expect(recorder.texts.where((_TextRecord record) => record.value == '暂无内容'), isEmpty);
      expect(_text(recorder, 'MUSIC ARCHIVE').y, closeTo(458.0, _epsilon));
    });
  });

  group('paint: recommendations (Qt/src/DiscoverMusicCard.cpp:235-310)', () {
    test('loadedCount > 2 draws the 音乐档案 / SELECTED PROGRAMS header at 490/495', () {
      final _Recorder recorder = _paint(_model(
        entries: <DiscoverEntry>[_entry(0), _entry(1), _entry(2)],
        loadedCount: 3,
      ));
      final _TextRecord heading = _text(recorder, '音乐档案');
      expect(heading.x, closeTo(383.0, _epsilon));
      expect(heading.y, closeTo(612.0, _epsilon));
      expect(heading.size, 17.0);
      expect(heading.weight, 'demibold');
      final _TextRecord sub = _text(recorder, 'SELECTED PROGRAMS');
      expect(sub.x, closeTo(478.0, _epsilon));
      expect(sub.y, closeTo(617.0, _epsilon));
      expect(sub.size, 10.0);
      expect(sub.color, _lightMuted);
    });

    test('loadedCount <= 2 omits the header but still paints the cards', () {
      final _Recorder recorder = _paint(_model(
        entries: <DiscoverEntry>[_entry(0), _entry(1)],
        loadedCount: 2,
      ));
      expect(recorder.texts.where((_TextRecord record) => record.value == '音乐档案'), isEmpty);
      expect(_onlyFillAt(recorder, 383.0, 352.0).color, _lightSoft);
    });

    test('featured card: soft ground, giant 01, copy column, framed artwork, hit', () {
      final _Recorder recorder = _paint(_model(
        entries: <DiscoverEntry>[_entry(0, image: 'art-0')],
        loadedCount: 1,
      ));
      final _FillRecord ground = _onlyFillAt(recorder, 383.0, 352.0);
      expect(ground.width, closeTo(749.76, _epsilon));
      expect(ground.height, closeTo(238.0, _epsilon));
      expect(ground.color, _lightSoft);
      final _TextRecord numeral = _text(recorder, '01');
      expect(numeral.x, closeTo(1012.76, _epsilon));
      expect(numeral.y, closeTo(483.0, _epsilon));
      expect(numeral.size, 94.0);
      expect(numeral.weight, 'light');
      expect(numeral.color, <double>[0.788, 0.812, 0.737, 1]);
      final _TextRecord eyebrow = _text(recorder, 'FEATURED ARCHIVE / 精选推荐');
      expect(eyebrow.x, closeTo(407.0, _epsilon));
      expect(eyebrow.y, closeTo(372.0, _epsilon));
      expect(eyebrow.size, 10.0);
      expect(eyebrow.color, _lightMuted);
      final _TextRecord title = _text(recorder, 'Archive 0');
      expect(title.x, closeTo(407.0, _epsilon));
      expect(title.y, closeTo(410.0, _epsilon));
      expect(title.size, 27.0);
      expect(title.weight, 'demibold');
      expect(title.color, _lightInk);
      final _TextRecord artist = _text(recorder, 'Artist 0');
      expect(artist.y, closeTo(504.0, _epsilon));
      expect(artist.size, 12.0);
      expect(artist.color, _lightMuted);
      final _TextRecord cta = _text(recorder, '打开音乐档案 ↗');
      expect(cta.x, closeTo(407.0, _epsilon));
      expect(cta.y, closeTo(554.0, _epsilon));
      expect(cta.size, 12.0);
      expect(cta.color, _lightInk);
      final _HitRecord hit = _hitAction(recorder, 'discover:item:0');
      expect(hit.x, closeTo(383.0, _epsilon));
      expect(hit.y, closeTo(352.0, _epsilon));
      expect(hit.width, closeTo(749.76, _epsilon));
      expect(hit.height, closeTo(238.0, _epsilon));
      expect(hit.label, 'Archive 0');
    });

    test('featured card uses the dark numeral when the model is dark', () {
      final _Recorder recorder = _paint(_model(
        dark: true,
        entries: <DiscoverEntry>[_entry(0, image: 'art-0')],
        loadedCount: 1,
      ));
      expect(_text(recorder, '01').color, <double>[0.24, 0.29, 0.23, 1]);
    });

    test('a song entry swaps the featured call to action', () {
      final _Recorder recorder = _paint(_model(
        entries: <DiscoverEntry>[_entry(0, kind: 'song', image: 'art-0')],
        loadedCount: 1,
      ));
      expect(_text(recorder, '▶ 播放歌曲').y, closeTo(554.0, _epsilon));
      expect(recorder.texts.where((_TextRecord record) => record.value == '打开音乐档案 ↗'), isEmpty);
    });

    test('framed artwork: shadow then paper then inset cover, rotated 0.0872664626', () {
      final _Recorder recorder = _paint(_model(
        entries: <DiscoverEntry>[_entry(0, image: 'art-0')],
        loadedCount: 1,
      ));
      // artSize = min(184, 749.76 * 0.4) = 184.
      final _FillRecord shadow = _onlyFillAt(recorder, 925.76, 387.0);
      expect(shadow.width, closeTo(184.0, _epsilon));
      expect(shadow.height, closeTo(184.0, _epsilon));
      expect(shadow.color, <double>[0.725, 0.749, 0.675, 1]);
      final _FillRecord paper = _onlyFillAt(recorder, 920.76, 379.0);
      expect(paper.width, closeTo(184.0, _epsilon));
      expect(paper.color, <double>[0.969, 0.957, 0.898, 1]);
      final _ImageRecord cover = recorder.images.single;
      expect(cover.key, 'art-0');
      expect(cover.x, closeTo(927.76, _epsilon));
      expect(cover.y, closeTo(386.0, _epsilon));
      expect(cover.width, closeTo(170.0, _epsilon));
      expect(cover.height, closeTo(170.0, _epsilon));
    });

    test('paint order: clip viewport, translate by -scroll, rotate inside framed art', () {
      final _Recorder recorder = _paint(_model(
        entries: <DiscoverEntry>[_entry(0, image: 'art-0')],
        loadedCount: 1,
      ));
      expect(recorder.commands.length, 9);
      expect(recorder.commands[0], <Object?>['save']);
      expect(recorder.commands[1], <Object?>['clip', 383.0, 352.0, 1154.0, 518.0]);
      expect(recorder.commands[2], <Object?>['translate', 0.0, 0.0]);
      expect(recorder.commands[3], <Object?>['save']);
      expect(recorder.commands[4][0], 'translate');
      expect(recorder.commands[4][1] as double, closeTo(1012.76, _epsilon));
      expect(recorder.commands[4][2] as double, closeTo(471.0, _epsilon));
      expect(recorder.commands[5], <Object?>['rotate', 0.0872664626]);
      expect(recorder.commands[6][0], 'translate');
      expect(recorder.commands[6][1] as double, closeTo(-1012.76, _epsilon));
      expect(recorder.commands[6][2] as double, closeTo(-471.0, _epsilon));
      expect(recorder.commands[7], <Object?>['restore']);
      expect(recorder.commands[8], <Object?>['restore']);
    });

    test('secondary card: night ground, five rings, 02, copy and open hit', () {
      final _Recorder recorder = _paint(_model(
        entries: <DiscoverEntry>[_entry(0, image: 'art-0'), _entry(1, kind: 'song', image: 'art-1')],
        loadedCount: 2,
      ));
      final _FillRecord ground = _onlyFillAt(recorder, 1150.76, 352.0);
      expect(ground.width, closeTo(386.24, _epsilon));
      expect(ground.height, closeTo(238.0, _epsilon));
      expect(ground.color, _night);
      final _TextRecord eyebrow = _text(recorder, 'NEXT DISCOVERY / 继续探索');
      expect(eyebrow.x, closeTo(1170.76, _epsilon));
      expect(eyebrow.y, closeTo(372.0, _epsilon));
      expect(eyebrow.size, 10.0);
      expect(eyebrow.color, _white);
      expect(recorder.circles.length, 5);
      // center = 1150.76 + 386.24 / 2 = 1343.88, cy = 122 + 310 = 432.
      expect(recorder.circles[0].cx, closeTo(1343.88, _epsilon));
      expect(recorder.circles[0].cy, closeTo(432.0, _epsilon));
      expect(recorder.circles[0].radius, closeTo(37.0, _epsilon));
      expect(recorder.circles[0].color, <double>[0.40, 0.46, 0.37, 1]);
      expect(recorder.circles[1].radius, closeTo(36.0, _epsilon));
      expect(recorder.circles[1].color, _night);
      expect(recorder.circles[2].radius, closeTo(28.0, _epsilon));
      expect(recorder.circles[3].radius, closeTo(27.0, _epsilon));
      expect(recorder.circles[4].cx, closeTo(1368.88, _epsilon));
      expect(recorder.circles[4].cy, closeTo(405.0, _epsilon));
      expect(recorder.circles[4].radius, closeTo(3.0, _epsilon));
      expect(recorder.circles[4].color, _amber);
      final _TextRecord numeral = _text(recorder, '02');
      expect(numeral.x, closeTo(1325.88, _epsilon));
      expect(numeral.y, closeTo(411.0, _epsilon));
      expect(numeral.size, 30.0);
      expect(numeral.weight, 'light');
      expect(numeral.color, _amber);
      final _TextRecord title = _text(recorder, 'Archive 1');
      expect(title.x, closeTo(1170.76, _epsilon));
      expect(title.y, closeTo(477.0, _epsilon));
      expect(title.size, 20.0);
      expect(title.color, _white);
      final _TextRecord artist = _text(recorder, 'Artist 1');
      expect(artist.y, closeTo(535.0, _epsilon));
      expect(artist.size, 11.0);
      expect(artist.color, _white);
      final _TextRecord cta = _text(recorder, '播放歌曲 ▶');
      expect(cta.y, closeTo(560.0, _epsilon));
      expect(cta.size, 11.0);
      expect(cta.color, _amber);
      final _HitRecord hit = _hitAction(recorder, 'discover:item:1');
      expect(hit.x, closeTo(1150.76, _epsilon));
      expect(hit.width, closeTo(386.24, _epsilon));
    });

    test('a single entry leaves the secondary slot as the daily recommendation invite', () {
      final _Recorder recorder = _paint(_model(
        entries: <DiscoverEntry>[_entry(0, image: 'art-0')],
        loadedCount: 1,
      ));
      expect(_text(recorder, '＋').y, closeTo(414.0, _epsilon));
      expect(_text(recorder, '＋').size, 24.0);
      final _TextRecord daily = _text(recorder, '每日推荐');
      expect(daily.x, closeTo(1170.76, _epsilon));
      expect(daily.y, closeTo(487.0, _epsilon));
      expect(daily.size, 23.0);
      expect(daily.weight, 'demibold');
      expect(daily.color, _white);
      expect(_text(recorder, '进入推荐 ↗').y, closeTo(548.0, _epsilon));
      final _HitRecord hit = _hitAction(recorder, 'discover:tab:daily');
      expect(hit.x, closeTo(1150.76, _epsilon));
      expect(hit.y, closeTo(352.0, _epsilon));
      expect(hit.width, closeTo(386.24, _epsilon));
      expect(hit.height, closeTo(238.0, _epsilon));
      expect(hit.label, '每日推荐');
    });

    test('tile: soft ground, cover, kind, title and artist stacked under the art', () {
      final _Recorder recorder = _paint(_model(
        entries: <DiscoverEntry>[_entry(0, image: 'art-0'), _entry(1, image: 'art-1'), _entry(2, image: 'art-2')],
        loadedCount: 3,
      ));
      final _FillRecord ground = _onlyFillAt(recorder, 383.0, 648.0);
      expect(ground.width, closeTo(216.4, _epsilon));
      expect(ground.height, closeTo(216.4, _epsilon));
      expect(ground.color, _lightSoft);
      // The featured card also paints an image, so select the tile cover by key.
      final _ImageRecord cover =
          recorder.images.firstWhere((_ImageRecord record) => record.key == 'art-2');
      expect(cover.key, 'art-2');
      expect(cover.x, closeTo(383.0, _epsilon));
      expect(cover.y, closeTo(648.0, _epsilon));
      expect(cover.width, closeTo(216.4, _epsilon));
      expect(cover.height, closeTo(216.4, _epsilon));
      final _TextRecord kind = _text(recorder, 'PLAYLIST / 歌单');
      expect(kind.x, closeTo(383.0, _epsilon));
      expect(kind.y, closeTo(876.4, _epsilon));
      expect(kind.size, 9.0);
      expect(kind.color, _lightMuted);
      final _TextRecord title = _text(recorder, 'Archive 2');
      expect(title.y, closeTo(896.4, _epsilon));
      expect(title.size, 14.0);
      expect(title.weight, 'demibold');
      final _TextRecord artist = _text(recorder, 'Artist 2');
      expect(artist.y, closeTo(942.4, _epsilon));
      expect(artist.size, 10.0);
      expect(artist.color, _lightMuted);
      expect(_hitAction(recorder, 'discover:item:2').y, closeTo(648.0, _epsilon));
    });

    test('tile without a cover draws the archive placeholder and its two-digit index', () {
      final _Recorder recorder = _paint(_model(
        entries: <DiscoverEntry>[_entry(0, image: 'art-0'), _entry(1, image: 'art-1'), _entry(2)],
        loadedCount: 3,
      ));
      expect(recorder.images.single.key, 'art-0');
      final _TextRecord kind = _text(recorder, 'PLAYLIST / 歌单');
      expect(kind.x, closeTo(397.0, _epsilon));
      expect(kind.y, closeTo(661.0, _epsilon));
      expect(kind.size, 10.0);
      final _TextRecord index = _text(recorder, '03');
      expect(index.x, closeTo(397.0, _epsilon));
      expect(index.y, closeTo(799.4, _epsilon));
      expect(index.size, 42.0);
      expect(index.weight, 'light');
      expect(index.color, _lightMuted);
    });

    test('a 2:1 cover keeps its aspect inside the square tile', () {
      final _Recorder recorder = _paint(_model(
        entries: <DiscoverEntry>[_entry(0, image: 'art-0'), _entry(1, image: 'art-1'),
            _entry(2, image: 'art-2', imageAspect: 2)],
        loadedCount: 3,
      ));
      final _ImageRecord cover =
          recorder.images.firstWhere((_ImageRecord record) => record.key == 'art-2');
      expect(cover.width, closeTo(216.4, _epsilon));
      expect(cover.height, closeTo(108.2, _epsilon));
      expect(cover.x, closeTo(383.0, _epsilon));
      expect(cover.y, closeTo(702.1, _epsilon));
    });

    test('a 1:1 cover fills the tile exactly', () {
      final _Recorder recorder = _paint(_model(
        entries: <DiscoverEntry>[_entry(0, image: 'art-0'), _entry(1, image: 'art-1'),
            _entry(2, image: 'art-2', imageAspect: 1)],
        loadedCount: 3,
      ));
      final _ImageRecord cover =
          recorder.images.firstWhere((_ImageRecord record) => record.key == 'art-2');
      expect(cover.width, closeTo(216.4, _epsilon));
      expect(cover.height, closeTo(216.4, _epsilon));
      expect(cover.x, closeTo(383.0, _epsilon));
      expect(cover.y, closeTo(648.0, _epsilon));
    });

    test('a degenerate aspect is clamped to 0.1 and centred', () {
      final _Recorder recorder = _paint(_model(
        entries: <DiscoverEntry>[_entry(0, image: 'art-0'), _entry(1, image: 'art-1'),
            _entry(2, image: 'art-2', imageAspect: 0.01)],
        loadedCount: 3,
      ));
      final _ImageRecord cover =
          recorder.images.firstWhere((_ImageRecord record) => record.key == 'art-2');
      expect(cover.width, closeTo(21.64, _epsilon));
      expect(cover.height, closeTo(216.4, _epsilon));
      expect(cover.x, closeTo(480.38, _epsilon));
      expect(cover.y, closeTo(648.0, _epsilon));
    });
  });

  group('paint: content hits are clipped to the viewport (Qt/src/DiscoverMusicCard.cpp:210-221)', () {
    test('a tile that overflows the viewport bottom is cut at 870', () {
      final _Recorder recorder = _paint(_model(
        entries: <DiscoverEntry>[_entry(0, image: 'art-0'), _entry(1, image: 'art-1'),
            _entry(2, image: 'art-2'), _entry(3, image: 'art-3')],
        loadedCount: 4,
      ));
      final _HitRecord tile = _hitAction(recorder, 'discover:item:2');
      expect(tile.y, closeTo(648.0, _epsilon));
      // 648 + 310.4 = 958.4, clamped to viewport top + height = 870.
      expect(tile.height, closeTo(222.0, _epsilon));
    });

    test('every visible hit stays inside the viewport and none overlap', () {
      final List<DiscoverEntry> entries = <DiscoverEntry>[
        for (int index = 0; index < 12; index++) _entry(index, image: 'art-$index'),
      ];
      final _Recorder recorder = _paint(_model(entries: entries, loadedCount: 12));
      final List<_HitRecord> hits = _itemHits(recorder);
      expect(hits.length, 7);
      for (final _HitRecord hit in hits) {
        expect(hit.x, greaterThanOrEqualTo(383.0 - _epsilon));
        expect(hit.y, greaterThanOrEqualTo(352.0 - _epsilon));
        expect(hit.x + hit.width, lessThanOrEqualTo(1537.0 + _epsilon));
        expect(hit.y + hit.height, lessThanOrEqualTo(870.0 + _epsilon));
      }
      for (int a = 0; a < hits.length; a++) {
        for (int b = a + 1; b < hits.length; b++) {
          final Rect left = Rect.fromLTWH(hits[a].x, hits[a].y, hits[a].width, hits[a].height);
          final Rect right = Rect.fromLTWH(hits[b].x, hits[b].y, hits[b].width, hits[b].height);
          expect(left.intersect(right).isEmpty, isTrue, reason: 'hit $a overlaps $b');
        }
      }
      // Qt/tests/NativeHudChecks.cpp: no discover:next / discover:prev in this card.
      expect(recorder.hits.where((_HitRecord hit) => hit.action.contains('discover:next')), isEmpty);
      expect(recorder.hits.where((_HitRecord hit) => hit.action.contains('discover:prev')), isEmpty);
    });

    test('scrolled to the end: special cards are gone, ten tiles are clipped in', () {
      final List<DiscoverEntry> entries = <DiscoverEntry>[
        for (int index = 0; index < 12; index++) _entry(index, image: 'art-$index'),
      ];
      final _Recorder recorder = _paint(_model(
        entries: entries,
        loadedCount: 12,
        scroll: DiscoverCard.layout(_stageBounds(1920), 12).maximumScroll,
      ));
      final List<_HitRecord> hits = _itemHits(recorder);
      expect(hits.length, 10);
      final _HitRecord first = _hitAction(recorder, 'discover:item:2');
      // 648 - 416.8 = 231.2 -> clipped up to the 352 viewport top.
      expect(first.y, closeTo(352.0, _epsilon));
      expect(first.height, closeTo(189.6, _epsilon));
      final _HitRecord secondRow = _hitAction(recorder, 'discover:item:7');
      // 976.4 - 416.8 = 559.6, 559.6 + 310.4 = 870 exactly.
      expect(secondRow.y, closeTo(559.6, _epsilon));
      expect(secondRow.height, closeTo(310.4, _epsilon));
      expect(recorder.hits.where((_HitRecord hit) => hit.action == 'discover:item:0'), isEmpty);
      expect(recorder.hits.where((_HitRecord hit) => hit.action == 'discover:item:1'), isEmpty);
    });

    test('the content layer translates by -scroll inside the clip', () {
      final _Recorder recorder = _paint(_model(
        entries: <DiscoverEntry>[_entry(0, image: 'art-0'), _entry(1, image: 'art-1'),
            _entry(2, image: 'art-2')],
        loadedCount: 3,
        scroll: 120,
      ));
      expect(recorder.commands[1], <Object?>['clip', 383.0, 352.0, 1154.0, 518.0]);
      expect(recorder.commands[2], <Object?>['translate', 0.0, -120.0]);
    });

    test('a card scrolled entirely above the viewport emits no hit at all', () {
      final _Recorder recorder = _paint(_model(
        entries: <DiscoverEntry>[_entry(0, image: 'art-0')],
        loadedCount: 12,
        scroll: DiscoverCard.layout(_stageBounds(1920), 12).maximumScroll,
      ));
      // -64.8..173.2 never crosses 352..870.
      expect(_itemHits(recorder), isEmpty);
    });
  });

  group('paint: scroll indicator (Qt/src/DiscoverMusicCard.cpp:312-324)', () {
    test('count 12 draws a 2px track at 1553 and a proportional thumb', () {
      final List<DiscoverEntry> entries = <DiscoverEntry>[
        for (int index = 0; index < 12; index++) _entry(index, image: 'art-$index'),
      ];
      final _Recorder recorder = _paint(_model(entries: entries, loadedCount: 12));
      final List<_FillRecord> stack = _fillsAt(recorder, 1553.0, 352.0);
      expect(stack.length, 2);
      final _FillRecord track = stack.firstWhere((_FillRecord fill) => _eq(fill.height, 518.0));
      expect(track.width, closeTo(2.0, _epsilon));
      expect(track.color, <double>[0.39, 0.43, 0.38, 0.16]);
      final _FillRecord thumb = stack.firstWhere((_FillRecord fill) => !_eq(fill.height, 518.0));
      // max(28, 518 * 518 / (518 + 416.8)) = 287.0389.
      expect(thumb.height, closeTo(287.0389, 1e-3));
      expect(thumb.color, _lightMuted);
      expect(thumb.width, closeTo(2.0, _epsilon));
    });

    test('the thumb slides with scroll: count 7, scroll 44.2 -> y 389.7566', () {
      final _Recorder recorder = _paint(_model(
        entries: <DiscoverEntry>[for (int index = 0; index < 7; index++) _entry(index, image: 'art-$index')],
        loadedCount: 7,
        scroll: 44.2,
      ));
      final _FillRecord thumb = recorder.fills.firstWhere((_FillRecord fill) =>
          _eq(fill.x, 1553.0) && _eq(fill.width, 2.0) && !_eq(fill.height, 518.0));
      // max(28, 518 * 518 / (518 + 88.4)) = 442.4868.
      expect(thumb.height, closeTo(442.4868, 1e-3));
      // 352 + (518 - 442.4868) * 44.2 / 88.4 = 389.7566.
      expect(thumb.y, closeTo(389.7566, 1e-3));
    });

    test('maximumScroll <= 0 draws no indicator at all', () {
      final _Recorder recorder = _paint(_model(
        entries: <DiscoverEntry>[_entry(0, image: 'art-0'), _entry(1, image: 'art-1')],
        loadedCount: 2,
      ));
      expect(_fillsAt(recorder, 1553.0, 352.0), isEmpty);
    });
  });

  group('paint: category picker (Qt/src/DiscoverMusicCard.cpp:326-342)', () {
    test('five columns of 224.4 wide cells at 285, wrapping every 44', () {
      final List<DiscoverChoice> categories = <DiscoverChoice>[
        for (int index = 0; index < 7; index++)
          DiscoverChoice(
            label: '分类 $index',
            action: 'discover:category:$index',
            selected: index == 0,
          ),
      ];
      final _Recorder recorder = _paint(_model(
        categories: categories,
        categoryPicker: true,
        categoryPage: 0,
        categoryPages: 1,
      ));
      final _TextRecord heading = _text(recorder, '选择歌单分类');
      expect(heading.x, closeTo(383.0, _epsilon));
      expect(heading.y, closeTo(359.0, _epsilon));
      expect(heading.size, 20.0);
      expect(heading.weight, 'demibold');
      final _HitRecord first = _hitAction(recorder, 'discover:category:0');
      // cell = (1154 - 32) / 5 = 224.4.
      expect(first.x, closeTo(383.0, _epsilon));
      expect(first.y, closeTo(407.0, _epsilon));
      expect(first.width, closeTo(224.4, _epsilon));
      expect(first.height, closeTo(36.0, _epsilon));
      final _HitRecord fifth = _hitAction(recorder, 'discover:category:4');
      expect(fifth.x, closeTo(1312.6, _epsilon));
      expect(fifth.y, closeTo(407.0, _epsilon));
      final _HitRecord sixth = _hitAction(recorder, 'discover:category:5');
      expect(sixth.x, closeTo(383.0, _epsilon));
      expect(sixth.y, closeTo(451.0, _epsilon));
    });

    test('the selected category draws a 2px amber bar under its button', () {
      final List<DiscoverChoice> categories = <DiscoverChoice>[
        for (int index = 0; index < 3; index++)
          DiscoverChoice(
            label: '分类 $index',
            action: 'discover:category:$index',
            selected: index == 1,
          ),
      ];
      final _Recorder recorder = _paint(_model(categories: categories, categoryPicker: true));
      // The button bottom border (1px) shares y=442 with the 2px amber bar.
      final _FillRecord bar = recorder.fills.firstWhere((_FillRecord fill) =>
          _eq(fill.x, 383.0 + 232.4) && _eq(fill.y, 442.0) && _eq(fill.height, 2.0));
      expect(bar.width, closeTo(224.4, _epsilon));
      expect(bar.color, _amber);
    });

    test('a single category echoes the status line at 680', () {
      final _Recorder recorder = _paint(_model(
        categories: <DiscoverChoice>[
          DiscoverChoice(label: '全部', action: 'discover:category:all', selected: true),
        ],
        categoryPicker: true,
        status: '暂无分类',
      ));
      final _TextRecord status = _text(recorder, '暂无分类');
      expect(status.x, closeTo(383.0, _epsilon));
      expect(status.y, closeTo(802.0, _epsilon));
      expect(status.size, 14.0);
      expect(status.color, _lightMuted);
    });

    test('the picker replaces the archive grid entirely', () {
      final _Recorder recorder = _paint(_model(
        entries: <DiscoverEntry>[_entry(0, image: 'art-0'), _entry(1, image: 'art-1')],
        loadedCount: 2,
        categories: <DiscoverChoice>[
          DiscoverChoice(label: '全部', action: 'discover:category:all', selected: true),
        ],
        categoryPicker: true,
      ));
      expect(_itemHits(recorder), isEmpty);
      expect(recorder.texts.where((_TextRecord record) => record.value == '音乐档案'), isEmpty);
      expect(recorder.images, isEmpty);
    });
  });

  group('paint: footer (Qt/src/DiscoverMusicCard.cpp:352-373)', () {
    test('rule at 756 plus the loaded counter', () {
      final _Recorder recorder = _paint(_model(loadedCount: 12));
      final _FillRecord rule = _onlyFillAt(recorder, 383.0, 878.0);
      expect(rule.width, closeTo(1154.0, _epsilon));
      expect(rule.height, closeTo(1.0, _epsilon));
      expect(rule.color, <double>[0.133, 0.165, 0.145, 0.18]);
      final _TextRecord status = _text(recorder, '已载入 12 条 / 滚轮浏览');
      expect(status.x, closeTo(383.0, _epsilon));
      expect(status.y, closeTo(901.0, _epsilon));
      expect(status.size, 11.0);
      expect(status.color, _lightMuted);
    });

    test('while loading the footer echoes the raw model status', () {
      final _Recorder recorder = _paint(_model(loadedCount: 12, loading: true, status: '正在载入分类…'));
      final _TextRecord status = _text(recorder, '正在载入分类…');
      expect(status.y, closeTo(901.0, _epsilon));
      expect(status.size, 11.0);
    });

    test('scroll hint flips to END OF ARCHIVE once the archive is exhausted', () {
      final _Recorder fresh = _paint(_model(loadedCount: 12));
      final _TextRecord hint = _text(fresh, 'SCROLL TO EXPLORE / 向下滚动');
      expect(hint.x, closeTo(1332.0, _epsilon));
      expect(hint.y, closeTo(901.0, _epsilon));
      expect(hint.size, 10.0);
      expect(hint.color, _lightMuted);
      final _Recorder bottom = _paint(_model(
        loadedCount: 12,
        scroll: DiscoverCard.layout(_stageBounds(1920), 12).maximumScroll,
      ));
      expect(_text(bottom, 'END OF ARCHIVE / 档案结束').x, closeTo(1332.0, _epsilon));
    });

    test('the category picker swaps the hint for a page counter and two buttons', () {
      final _Recorder recorder = _paint(_model(
        categoryPicker: true,
        categoryPage: 1,
        categoryPages: 3,
        loadedCount: 12,
      ));
      final _TextRecord counter = _text(recorder, '2 / 3');
      expect(counter.y, closeTo(901.0, _epsilon));
      expect(counter.size, 11.0);
      final _HitRecord previous = _hitAction(recorder, 'discover:category-page:prev');
      expect(previous.x, closeTo(1325.0, _epsilon));
      expect(previous.y, closeTo(892.0, _epsilon));
      expect(previous.width, closeTo(100.0, _epsilon));
      expect(previous.height, closeTo(34.0, _epsilon));
      expect(previous.label, '↑ 上一页');
      final _HitRecord next = _hitAction(recorder, 'discover:category-page:next');
      expect(next.x, closeTo(1437.0, _epsilon));
      expect(next.label, '下一页 ↓');
    });

    test('more replaces the hint with a load-more button that knows loading', () {
      final _Recorder recorder = _paint(_model(loadedCount: 12, more: true));
      final _HitRecord more = _hitAction(recorder, 'discover:more');
      expect(more.x, closeTo(1417.0, _epsilon));
      expect(more.y, closeTo(892.0, _epsilon));
      expect(more.width, closeTo(120.0, _epsilon));
      expect(more.height, closeTo(34.0, _epsilon));
      expect(more.label, '加载更多 ↓');
      final _Recorder busy = _paint(_model(loadedCount: 12, more: true, loading: true));
      expect(_hitAction(busy, 'discover:more').label, '载入中…');
    });

    test('an empty archive gets neither hint nor button', () {
      final _Recorder recorder = _paint(_model());
      expect(recorder.texts.where((_TextRecord record) => record.value.contains('SCROLL TO EXPLORE')), isEmpty);
      expect(recorder.hits.where((_HitRecord hit) => hit.action == 'discover:more'), isEmpty);
    });
  });

  group('paint: dark theme (Qt/src/DiscoverMusicCard.cpp:59-64)', () {
    test('dark empty state uses the dark muted ink on the dark paper', () {
      final _Recorder recorder = _paint(_model(dark: true));
      expect(recorder.fills[0].color, _darkPaper);
      expect(_text(recorder, 'MUSIC ARCHIVE').color, _darkMuted);
      expect(_text(recorder, '暂无内容').color, _darkInk);
      expect(_text(recorder, '切换上方分类，继续探索音乐资料库。').color, _darkMuted);
    });

    test('dark tabs: selected label ink, unselected muted, underline still amber', () {
      final _Recorder recorder = _paint(_model(dark: true));
      expect(_text(recorder, '推荐歌单').color, _darkInk);
      expect(_text(recorder, '每日推荐').color, _darkMuted);
      expect(_onlyFillAt(recorder, 474.4, 291.0).color, _amber);
    });

    test('dark theme swaps the tile ground soft literal, keeps light soft otherwise', () {
      final List<DiscoverEntry> entries = <DiscoverEntry>[
        _entry(0, image: 'art-0'),
        _entry(1, image: 'art-1'),
        _entry(2, image: 'art-2'),
      ];
      final _Recorder light = _paint(_model(entries: entries, loadedCount: 3));
      expect(_onlyFillAt(light, 383.0, 648.0).color, _lightSoft);
      final _Recorder dark = _paint(_model(dark: true, entries: entries, loadedCount: 3));
      expect(_onlyFillAt(dark, 383.0, 648.0).color, _darkSoft);
    });
  });

  group('paint: stage sweep (1280 / 1920 / 2560)', () {
    test('1280 stage: 1180 wide panel at x50, tile hits 200.4 wide', () {
      final _Recorder recorder = _paint(_model(
        bounds: _stageBounds(1280),
        entries: <DiscoverEntry>[_entry(0, image: 'art-0'), _entry(1, image: 'art-1'),
            _entry(2, image: 'art-2')],
        loadedCount: 3,
      ));
      expect(recorder.fills[0].x, closeTo(50.0, _epsilon));
      expect(recorder.fills[0].width, closeTo(1180.0, _epsilon));
      expect(_text(recorder, '02 / MUSIC DIRECTORY').x, closeTo(103.0, _epsilon));
      expect(_hitAction(recorder, 'discover:item:2').width, closeTo(200.4, _epsilon));
      expect(_hitAction(recorder, 'discover:item:0').width, closeTo((1074.0 - 18.0) * 0.66, _epsilon));
    });

    test('2560 stage: modal stays 1260 wide at x650, tile hits 216.4 wide', () {
      final _Recorder recorder = _paint(_model(
        bounds: _stageBounds(2560),
        entries: <DiscoverEntry>[_entry(0, image: 'art-0'), _entry(1, image: 'art-1'),
            _entry(2, image: 'art-2')],
        loadedCount: 3,
      ));
      expect(recorder.fills[0].x, closeTo(650.0, _epsilon));
      expect(recorder.fills[0].width, closeTo(1260.0, _epsilon));
      expect(_text(recorder, '02 / MUSIC DIRECTORY').x, closeTo(703.0, _epsilon));
      expect(_hitAction(recorder, 'discover:item:2').width, closeTo(216.4, _epsilon));
    });
  });
}
