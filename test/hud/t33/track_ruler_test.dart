// T33-C18 A4 (lib/hud/widgets/track_ruler.dart) + A5 (this test file) tests.
// RED/GREEN NOT EXECUTED - execution forbidden by task scope.
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:rhine_music_database/hud/pages/chrome.dart';
import 'package:rhine_music_database/hud/widgets/track_ruler.dart';

class FakeSink implements HudSurfaceSink {
  final List<HudWireCommand> ops = <HudWireCommand>[];
  final List<HudHit> hits = <HudHit>[];
  @override
  void op(HudWireCommand command) => ops.add(command);
  @override
  void hit(HudHit hit) => hits.add(hit);
}

class FakeText implements HudTextPort {
  final List<List<Object?>> rolled = <List<Object?>>[];
  @override
  double glyphWidth(String value, double size, [String weight = 'regular']) => value.length * size * 0.5;
  @override
  double glyphInset(String value, double size, [String weight = 'regular']) => 0;
  @override
  String fit(String value, double size, double width, [String weight = 'regular']) => value;
  @override
  void rolling(String key, String value, double x, double y, double size, String weight,
      double tracking, bool numeric) {
    rolled.add(<Object?>[key, value, x, y, size, weight, tracking, numeric]);
  }
}

List<HudWireCommand> textsAt(List<HudWireCommand> ops, double y) =>
    ops.where((HudWireCommand c) => c[0] == 'text' && c[3] == y).toList();

List<TrackListItem> songs(int n) => <TrackListItem>[
  for (int i = 0; i < n; i++) TrackListItem(title: 'T$i', kind: 'song'),
];

TrackListScope scope({String provider = 'netease', String identity = '7', bool dir = false, int lane = 0, String group = 'g'}) =>
    TrackListScope(provider: provider, directoryIdentity: identity, hasDirectory: dir, selectedLane: lane, groupName: group);

void main() {
  test('TrackRulerRow defaults (NativeHud.h:168-173)', () {
    final TrackRulerRow r = TrackRulerRow();
    expect(r.centerY, 0);
    expect(r.textRight, 0);
    expect(r.emphasis, 0);
    expect(r.opacity, 1);
  });

  test('scopeKey concatenation (NativeHud.cpp:518)', () {
    expect(scope().scopeKey, 'netease:7:0:g');
    expect(scope(dir: true).scopeKey, 'netease:7::g');
    expect(scope(lane: 3).scopeKey, 'netease:7:3:g');
  });

  test('position resets to selected when scope changed, curve missing, reduced, or jump > 8 (NativeHud.cpp:524-525)', () {
    final HudTrackRuler r = HudTrackRuler(FakeSink(), FakeText());
    List<Object?>? got;
    double run(String lastScope, int lastTarget, bool reduced, ReelCurve? curve, int selected) =>
        r.archiveTrackPosition(selected: selected, scope: scope(), lastScope: lastScope, lastTarget: lastTarget,
            reduced: reduced, lastTime: 1.0, curve: curve, onCurve: (ReelCurve c, TrackListScope s, int t) { got = <Object?>[c, s, t]; });
    // (1) changed collection: the first predicate is already true.
    expect(run('other', 0, false, null, 12), 12);
    expect(got, isNotNull);
    // NativeHud.cpp:530-531 record the scope and the target on every path, including this one.
    expect((got![1] as TrackListScope).scopeKey, 'netease:7:0:g');
    expect(got![2], 12);
    // NativeHud.cpp:525-526 ReelCurve(selected, selected, 0, lastTime - 0.64, 0.64).
    final ReelCurve reset1 = got![0] as ReelCurve;
    expect(reset1.from, 12);
    expect(reset1.to, 12);
    expect(reset1.duration, 0.64);
    expect(reset1.startTime, closeTo(0.36, 1e-9));
    // (2) reduced.
    expect(run('netease:7:0:g', 0, true, null, 3), 3);
    // (3) no curve at all.
    expect(run('netease:7:0:g', 20, false, null, 3), 3);
    // (4) same collection and a live curve, but the sampled position is more than 8 rows away
    // from the new selection: NativeHud.cpp:524 still resets. A flat curve sampled at the end
    // of its duration gives exactly 20, while the new selection is 29.
    final ReelCurve flat = ReelCurve(20, 20, 0, 0, 0.64);
    expect(flat.sample(1.0), closeTo(20, 1e-9));
    expect(run('netease:7:0:g', 20, false, flat, 29), 29);
    final ReelCurve reset2 = got![0] as ReelCurve;
    expect(reset2.from, 29);
    expect(reset2.to, 29);
    expect(reset2.duration, 0.64);
    expect(reset2.startTime, closeTo(0.36, 1e-9));
    expect((got![1] as TrackListScope).scopeKey, 'netease:7:0:g');
    expect(got![2], 29);
  });

  test('position follows the curve when the same collection stays put (NativeHud.cpp:527-530)', () {
    final HudTrackRuler r = HudTrackRuler(FakeSink(), FakeText());
    final ReelCurve c = ReelCurve(4, 4, 0, 0, 0.64);
    List<Object?>? got;
    final double p = r.archiveTrackPosition(selected: 4, scope: scope(), lastScope: 'netease:7:0:g', lastTarget: 4,
        reduced: false, lastTime: 1.0, curve: c,
        onCurve: (ReelCurve cc, TrackListScope s, int t) { got = <Object?>[cc, s, t]; });
    expect(p, closeTo(4, 0.0001));
    expect(c.sample(0), closeTo(4, 0.0001));
    // lastTarget == selected -> Qt keeps m_trackListCurve instead of rebuilding it (:529-530).
    expect(identical(got![0], c), isTrue);
    expect((got![1] as TrackListScope).scopeKey, 'netease:7:0:g');
    expect(got![2], 4);
  });

  test('rapid reversal continues from the sampled position and velocity (NativeHud.cpp:527-529)', () {
    final HudTrackRuler r = HudTrackRuler(FakeSink(), FakeText());
    // from != to so the sampled velocity is non zero at an interior curve time.
    final ReelCurve c = ReelCurve(20, 10, 0, 0, 0.64);
    final List<double> sampled = c.samplePair(0.2);
    // UiMotion.cpp:70-72 with from 20, to 10, velocity 0, t = 0.2 / 0.64 = 0.3125 (index 15):
    //   to + (displacement + 10 * displacement * t) * exp(-10 * t), displacement = 10,
    //   = 10 + 41.25 * exp(-3.125).
    expect(sampled[0], closeTo(10 + 41.25 * math.exp(-3.125), 1e-9));
    final int selected = (sampled[0] + 7).round();
    expect((selected - sampled[0]).abs() <= 8, isTrue);
    expect(selected == 20, isFalse);
    List<Object?>? got;
    final double p = r.archiveTrackPosition(selected: selected, scope: scope(), lastScope: 'netease:7:0:g',
        lastTarget: 0, reduced: false, lastTime: 0.2, curve: c,
        onCurve: (ReelCurve cc, TrackListScope s, int t) { got = <Object?>[cc, s, t]; });
    expect(p, closeTo(sampled[0], 1e-9));
    // NativeHud.cpp:528 ReelCurve(position[0], selected, position[1], lastTime, 0.64).
    final ReelCurve next = got![0] as ReelCurve;
    expect(next.from, closeTo(sampled[0], 1e-9));
    expect(next.to, selected);
    expect(next.velocity, closeTo(sampled[1], 1e-9));
    expect(next.startTime, 0.2);
    expect(next.duration, 0.64);
    expect((got![1] as TrackListScope).scopeKey, 'netease:7:0:g');
    expect(got![2], selected);
  });

  test('reel curve converges to its target over 0.64s (UiMotion::ReelCurve equivalent, E3)', () {
    final ReelCurve c = ReelCurve(0, 10, 0, 0, 0.64);
    expect(c.sample(0), closeTo(0, 0.0001));
    expect(c.sample(0.64), closeTo(10, 0.0001));
    // UiMotion.cpp:68-73 with from 0, to 10, velocity 0, duration 0.64: displacement = -10,
    // impulse = 0, t = 0.32 / 0.64 = 0.5 (table index 24) ->
    //   to + (displacement + (impulse + 10 * displacement) * t) * exp(-10 * t) = 10 - 60 * exp(-5).
    expect(c.sample(0.32), closeTo(10 - 60 * math.exp(-5), 1e-9));
    double p(int i) {
      final double t = i / 48.0;
      return 10 + (-10 + (-100) * t) * math.exp(-10 * t);
    }
    expect(c.sample(0.32), closeTo(p(24), 1e-12));
    // UiMotion.cpp:76-84: samplePair()[1] is the velocity handed to the next curve
    // (NativeHud.cpp:528): ((p(i + 1) - p(i)) * 48) / duration.
    expect(c.samplePair(0.32)[1], closeTo((p(25) - p(24)) * 48 / 0.64, 1e-9));
  });

  test('row opacity, offset, and hit thresholds (NativeHud.cpp:556-589)', () {
    final FakeSink s = FakeSink();
    HudTrackRuler(s, FakeText()).archiveTrackList(x: 1920 - 789, width: 1920, values: songs(40), selected: 20,
        selectedTitle: 'T20', position: 20);
    final List<HudHit> hits = s.hits;
    expect(hits.length, 9);
    expect(hits.where((HudHit h) => h.action == 'open').length, 1);
    expect(hits.where((HudHit h) => h.action.startsWith('music:index:')).length, 8);
    expect(hits.every((HudHit h) => h.width == (1920 - 160) - (1920 - 789) - 68), isTrue);
    expect(hits.every((HudHit h) => h.height == 44), isTrue);
    expect(hits.every((HudHit h) => h.x == 1920 - 789), isTrue);
    // Qt (NativeHud.cpp:564) offset = distance <= 1 ? distance * 88 : 88 + (distance - 1) * 52,
    // so the outermost drawn row (distance 4) sits at 88 + 3 * 52 = 244 from the title baseline.
    expect(hits.first.y, 509 - (88 + 3 * 52) - 4);
    expect(hits.last.y, 509 + (88 + 3 * 52) - 4);
    expect(hits.every((HudHit h) => h.y >= 509 - 270 - 4 && h.y <= 509 + 270 - 4), isTrue);
  });

  test('non-song rows are skipped (NativeHud.cpp:560)', () {
    final FakeSink s = FakeSink();
    final List<TrackListItem> values = <TrackListItem>[
      for (int i = 0; i < 40; i++) TrackListItem(title: 'T$i', kind: i.isEven ? 'song' : 'album'),
    ];
    HudTrackRuler(s, FakeText()).archiveTrackList(x: 1131, width: 1920, values: values, selected: 20,
        selectedTitle: 'T20', position: 20);
    expect(s.hits.length, 5);
  });

  test('clip and save/restore envelope (NativeHud.cpp:554/591)', () {
    final FakeSink s = FakeSink();
    HudTrackRuler(s, FakeText()).archiveTrackList(x: 1131, width: 1920, values: songs(40), selected: 20,
        selectedTitle: 'T20', position: 20);
    expect(s.ops.first, <Object?>['save']);
    expect(s.ops[1], <Object?>['clip', 1131 - 4, 509 - 290, 1920 - 1131, 610]);
    expect(s.ops.last, <Object?>['restore']);
  });

  test('offsets use 88 then 52 stride (NativeHud.cpp:564)', () {
    final FakeSink s = FakeSink();
    HudTrackRuler(s, FakeText()).archiveTrackList(x: 1131, width: 1920, values: songs(40), selected: 20,
        selectedTitle: 'T20', position: 20);
    final List<List<double>> ys = <List<double>>[
      for (final HudHit h in s.hits) <double>[h.y],
    ];
    expect(ys.length, 9);
    expect(s.hits.map((HudHit h) => h.y).toList(), <double>[
      509 - (88 + 3 * 52) - 4,
      509 - (88 + 2 * 52) - 4,
      509 - (88 + 1 * 52) - 4,
      509 - 88 - 4,
      509 - 4,
      509 + 88 - 4,
      509 + (88 + 1 * 52) - 4,
      509 + (88 + 2 * 52) - 4,
      509 + (88 + 3 * 52) - 4,
    ]);
  });

  test('row text keeps the Qt blend and the per row save/alpha/text/restore envelope (NativeHud.cpp:567-585)', () {
    final FakeSink s = FakeSink();
    final FakeText t = FakeText();
    HudTrackRuler(s, t).archiveTrackList(x: 1131, width: 1920, values: songs(40), selected: 20,
        selectedTitle: 'T20', position: 20);
    // NativeHud.cpp:575-576: the selected row shows the current title, its neighbours the list titles.
    final HudWireCommand selectedRow = textsAt(s.ops, 509).single;
    expect(selectedRow[1], 'T20');
    // emphasis == 1 -> ink() is kept verbatim, calibrated marker included (NativeHud.cpp:568).
    expect(selectedRow[7], <Object?>[0.08, 0.085, 0.075, 1, 'calibratedRGB']);
    // emphasis == 0 -> the gray blend, rebuilt as a 4 element array so the calibrated marker of
    // ink() is dropped (NativeHud.cpp:570-573). distance 4 sits at 88 + 3 * 52 = 244 from the title.
    final HudWireCommand farRow = textsAt(s.ops, 509 - 244).single;
    expect(farRow[1], 'T16');
    expect(farRow[7], <Object?>[0.49, 0.49, 0.46, 1]);
    // NativeHud.cpp:582-585: every row is save -> alpha(opacity) -> text -> restore.
    final int at = s.ops.indexOf(selectedRow);
    expect(s.ops[at - 2], <Object?>['save']);
    expect(s.ops[at - 1], <Object?>['alpha', 1.0]);
    expect(s.ops[at + 1], <Object?>['restore']);
    // Qt anchors the rows with text() itself (NativeHud.cpp:582-585), never rollingText():
    // the rolling port of the text port must stay untouched.
    expect(t.rolled, isEmpty);
  });

  test('ruler spine palette and geometry (NativeHud.cpp:596-598)', () {
    final FakeSink s = FakeSink();
    HudTrackRuler(s, FakeText()).archiveTrackRuler(x: 1760, centerY: 523, rows: <TrackRulerRow>[]);
    expect(s.ops.first, <Object?>['fill', <Object?>[0.46, 0.48, 0.37, 0.75], 1760, 523 - 272, 1.5, 544]);
    expect(s.ops.where((HudWireCommand c) => c[0] == 'path' && c[2] == 2).length, 1);
    expect(s.ops.where((HudWireCommand c) => c[0] == 'fill-path').length, 1);
    expect(s.ops.where((HudWireCommand c) => c[0] == 'fill' && c[4] == 16 && c[5] == 2).length, 1);
  });

  test('dark ruler palette (NativeHud.cpp:597)', () {
    final FakeSink s = FakeSink();
    HudTrackRuler(s, FakeText(), dark: true).archiveTrackRuler(x: 1760, centerY: 500, rows: <TrackRulerRow>[]);
    expect(s.ops.first, <Object?>['fill', <Object?>[0.65, 0.67, 0.55, 0.8], 1760, 228, 1.5, 544]);
  });

  test('row leader: length 14+36*emphasis and alpha 0.12+0.16*emphasis (NativeHud.cpp:602-608)', () {
    final FakeSink s = FakeSink();
    HudTrackRuler(s, FakeText()).archiveTrackRuler(x: 1760, centerY: 500,
        rows: <TrackRulerRow>[TrackRulerRow(centerY: 500, textRight: 900, emphasis: 1, opacity: 1)]);
    expect(s.ops.where((HudWireCommand c) => c[0] == 'fill' && c[4] == 50 && c[5] == 1.2).length, 1);
    final HudWireCommand leader = s.ops.firstWhere((HudWireCommand c) => c[0] == 'fill' && c[5] == 0.8);
    expect((leader[1] as List<Object?>)[3], closeTo(0.28, 0.0001));
    // Qt (NativeHud.cpp:604): leaderStart = min(x - length - 8, textRight + 20)
    //                          width       = max(0, x - length - leaderStart)
    // with x = 1760, length = 14 + 36 * 1 = 50, textRight = 900 -> min(1702, 920) = 920, width 790.
    expect(leader[2], 920);
    expect(leader[4], 1760 - 50 - 920);
    expect(s.ops.first[0], 'fill');
    expect(s.ops.where((HudWireCommand c) => c[0] == 'alpha').length, 1);
  });

  test('ruler emits alpha per row then restores (NativeHud.cpp:599-608)', () {
    final FakeSink s = FakeSink();
    HudTrackRuler(s, FakeText()).archiveTrackRuler(x: 1760, centerY: 500, rows: <TrackRulerRow>[
      TrackRulerRow(centerY: 480, textRight: 800, emphasis: 0, opacity: 0.5),
      TrackRulerRow(centerY: 500, textRight: 900, emphasis: 1, opacity: 1),
    ]);
    expect(s.ops.where((HudWireCommand c) => c[0] == 'alpha').length, 2);
    expect(s.ops.where((HudWireCommand c) => c[0] == 'save').length, 2);
    expect(s.ops.where((HudWireCommand c) => c[0] == 'restore').length, 2);
  });
}