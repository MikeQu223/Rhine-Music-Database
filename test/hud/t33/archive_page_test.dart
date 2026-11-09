// T33-C18 A2 (lib/hud/pages/archive_page.dart) + A5 (this test file) tests.
// RED/GREEN NOT EXECUTED - execution forbidden by task scope.
import 'package:flutter_test/flutter_test.dart';
import 'package:rhine_music_database/hud/pages/archive_page.dart';
import 'package:rhine_music_database/hud/pages/chrome.dart';

class FakeSink implements HudSurfaceSink {
  final List<HudCommand> ops = <HudCommand>[];
  final List<HudHit> hits = <HudHit>[];
  @override
  void op(HudCommand command) => ops.add(command);
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

List<HudCommand> textsAt(List<HudCommand> ops, double y) =>
    ops.where((HudCommand c) => c[0] == 'text' && c[3] == y).toList();

HudArchiveState st({
  String libraryName = 'LIB',
  int libraryIndex = 0,
  int libraryTotal = 10,
  int selectedLane = 0,
  int laneCount = 5,
  int sourceOrderIndex = 1,
  String provider = 'netease',
  bool isLocal = true,
  bool isSiren = false,
  bool directory = false,
  String? directoryKind,
  String uid = 'u1',
  bool restoringAccount = false,
  bool sourceLoading = false,
  bool trackListMode = false,
  bool emptyCurrent = false,
  String currentKind = 'playlist',
  bool libraryItemsEmpty = false,
  int libraryItemsLength = 10,
  int selectedPhysicalRow = 0,
  String? sourceMessage,
}) =>
    HudArchiveState(
      libraryName: libraryName,
      libraryIndex: libraryIndex,
      libraryTotal: libraryTotal,
      selectedLane: selectedLane,
      laneCount: laneCount,
      sourceOrderIndex: sourceOrderIndex,
      provider: provider,
      isLocal: isLocal,
      isSiren: isSiren,
      directory: directory,
      directoryKind: directoryKind,
      uid: uid,
      restoringAccount: restoringAccount,
      sourceLoading: sourceLoading,
      trackListMode: trackListMode,
      current: emptyCurrent ? null : ArchiveItem(id: 'a1', title: 'TITLE', artist: 'ARTIST', kind: currentKind),
      libraryItemsEmpty: libraryItemsEmpty,
      libraryItemsLength: libraryItemsLength,
      selectedPhysicalRow: selectedPhysicalRow,
      sourceMessage: sourceMessage,
    );

List<String> actionsOf(HudArchiveState s) {
  final FakeSink sink = FakeSink();
  HudArchivePage(sink, FakeText()).archive(
    width: 1920,
    s: s,
    drawTrackList: (double w, HudArchiveState x) {},
    drawEmpty: (double w, HudArchiveState x) {},
    supportsTrackList: (HudArchiveState x) => false,
  );
  return sink.hits.map((HudHit h) => h.action).toList();
}

HudHit hitOf(List<HudHit> hits, String action) => hits.firstWhere((HudHit h) => h.action == action);

void main() {
  // A2 review F2: archive() / archiveTabButton() / trackNumber() never read laneCount. The five
  // lane model (NativeHudController.cpp:183-185) belongs to the host that builds HudArchiveState;
  // this page only consumes selectedLane, so there is no page level assertion to pin here. The
  // former "expect(st().laneCount, 5)" only restated a test fixture default and was dropped.

  test('eight slot ticks, stride 26 from nav+85, selected bar 909/33, others 920/12', () {
    final FakeSink s = FakeSink();
    HudArchivePage(s, FakeText()).archive(width: 1920, s: st(libraryItemsEmpty: false, selectedPhysicalRow: 2),
        drawTrackList: (double w, HudArchiveState x) {}, drawEmpty: (double w, HudArchiveState x) {},
        supportsTrackList: (HudArchiveState x) => false);
    final double nav = 1920 * 0.2625;
    expect(s.hits.where((HudHit h) => h.action.startsWith('music:slot:')).length, 8);
    expect(hitOf(s.hits, 'prev').x, nav);
    expect(hitOf(s.hits, 'prev').y, 903);
    expect(hitOf(s.hits, 'prev').width, 46);
    expect(hitOf(s.hits, 'prev').height, 46);
    expect(hitOf(s.hits, 'next').x, nav + 320);
    final HudHit third = hitOf(s.hits, 'music:slot:2');
    expect(third.x, nav + 85 + 2 * 26 - 6);
    expect(third.y, 900);
    expect(third.width, 26);
    expect(third.height, 50);
    expect(hitOf(s.hits, 'music:slot:2').label, '选曲 3');
    final List<HudCommand> bars = s.ops.where((HudCommand c) => c[0] == 'fill' && c[5] == 33).toList();
    expect(bars.length, 1);
    expect(bars.single[4], 2);
    expect((bars.single[1] as List<Object?>)[3], 1);
    final List<HudCommand> small = s.ops.where((HudCommand c) => c[0] == 'fill' && c[5] == 12).toList();
    expect(small.length, 7);
  });

  test('slot ticks are absent when the lane is empty (NativeHud.cpp:473)', () {
    final List<String> a = actionsOf(st(libraryItemsEmpty: true));
    expect(a.any((String x) => x.startsWith('music:slot:')), isFalse);
  });

  test('column arrows at width*0.5234375 with column-next at +310 (NativeHud.cpp:479-490)', () {
    final FakeSink s = FakeSink();
    HudArchivePage(s, FakeText()).archive(width: 1920, s: st(), drawTrackList: (double w, HudArchiveState x) {},
        drawEmpty: (double w, HudArchiveState x) {}, supportsTrackList: (HudArchiveState x) => false);
    final double col = 1920 * 0.5234375;
    expect(hitOf(s.hits, 'column-prev').x, col);
    expect(hitOf(s.hits, 'column-next').x, col + 310);
    expect(hitOf(s.hits, 'column-prev').y, 903);
  });

  test('collection caption uses pad(sourceOrderIndex+1) / pad(kugou?4:5) (NativeHud.cpp:482)', () {
    final FakeSink s = FakeSink();
    HudArchivePage(s, FakeText()).archive(width: 1920, s: st(sourceOrderIndex: 0, provider: 'kugou'),
        drawTrackList: (double w, HudArchiveState x) {}, drawEmpty: (double w, HudArchiveState x) {},
        supportsTrackList: (HudArchiveState x) => false);
    final List<HudCommand> cap = textsAt(s.ops, 904);
    expect(cap.single[1], 'COLLECTION 01 / 04');
    expect(cap.single[2], 1920 * 0.5234375 + 70);
  });

  test('directory caption uses TRACK COLUMN nn / 05 (NativeHud.cpp:487-488)', () {
    final FakeSink s = FakeSink();
    HudArchivePage(s, FakeText()).archive(width: 1920, s: st(directory: true, directoryKind: 'album', selectedLane: 2),
        drawTrackList: (double w, HudArchiveState x) {}, drawEmpty: (double w, HudArchiveState x) {},
        supportsTrackList: (HudArchiveState x) => false);
    final List<HudCommand> cap = textsAt(s.ops, 916);
    expect(cap.single[1], 'TRACK COLUMN 03 / 05');
  });

  test('Tab Mode button rect and verbatim label (NativeHud.cpp:500-503)', () {
    final FakeSink s = FakeSink();
    HudArchivePage(s, FakeText()).archiveTabButton(width: 1920, trackListMode: true);
    final HudHit h = s.hits.single;
    expect(h.x, 1920 - 340 - 8);
    expect(h.y, 854);
    expect(h.width, 186);
    expect(h.height, 48);
    expect(h.action, 'archive:tab-mode');
    expect(h.label, 'Tab Mode，按 Tab 切换');
    expect((textsAt(s.ops, 866).single)[4], 18);
    expect((textsAt(s.ops, 866).single)[5], 'bold');
    expect(s.ops.where((HudCommand c) => c[0] == 'path').length, 2);
  });

  test('Tab Mode text weight follows trackListMode (NativeHud.cpp:503)', () {
    final FakeSink s = FakeSink();
    HudArchivePage(s, FakeText()).archiveTabButton(width: 1920, trackListMode: false);
    expect((textsAt(s.ops, 866).single)[5], 'regular');
  });

  test('Tab Mode button only appears when supportsTrackList is true (NativeHud.cpp:491)', () {
    final FakeSink s = FakeSink();
    HudArchivePage(s, FakeText()).archive(width: 1920, s: st(trackListMode: true, currentKind: 'song'),
        drawTrackList: (double w, HudArchiveState x) {}, drawEmpty: (double w, HudArchiveState x) {},
        supportsTrackList: (HudArchiveState x) => true);
    expect(s.hits.any((HudHit h) => h.action == 'archive:tab-mode'), isTrue);
    final FakeSink t = FakeSink();
    HudArchivePage(t, FakeText()).archive(width: 1920, s: st(trackListMode: true, currentKind: 'song'),
        drawTrackList: (double w, HudArchiveState x) {}, drawEmpty: (double w, HudArchiveState x) {},
        supportsTrackList: (HudArchiveState x) => false);
    expect(t.hits.any((HudHit h) => h.action == 'archive:tab-mode'), isFalse);
  });

  test('showTrackList is gated on trackListMode && kind == song (NativeHud.cpp:428-432)', () {
    bool drawn = false;
    final FakeSink s = FakeSink();
    HudArchivePage(s, FakeText()).archive(width: 1920, s: st(trackListMode: true, currentKind: 'song'),
        drawTrackList: (double w, HudArchiveState x) { drawn = true; },
        drawEmpty: (double w, HudArchiveState x) {}, supportsTrackList: (HudArchiveState x) => true);
    expect(drawn, isTrue);
    bool drawn2 = false;
    final FakeSink t = FakeSink();
    final FakeText tt = FakeText();
    HudArchivePage(t, tt).archive(width: 1920, s: st(trackListMode: true, currentKind: 'album'),
        drawTrackList: (double w, HudArchiveState x) { drawn2 = true; },
        drawEmpty: (double w, HudArchiveState x) {}, supportsTrackList: (HudArchiveState x) => true);
    expect(drawn2, isFalse);
    // Qt roll() (NativeHud.cpp:97-101) = fit() then rollingText(), i.e. the 'music-source'
    // pass-through both scrolls and emits, so it is asserted on the port, not on a direct text op.
    final List<Object?> source = tt.rolled.firstWhere((List<Object?> r) => r[0] == 'music-source');
    expect(source[1], 'MUSIC DATABASE / LIB');
    expect(source[2], 1920 - 789);
    expect(source[3], 471);
    expect(source[4], 12);
  });

  test('play-all gating (NativeHud.cpp:420-426)', () {
    expect(actionsOf(st()).contains('music:play-loaded'), isFalse);
    expect(actionsOf(st(selectedLane: 1)).contains('music:play-loaded'), isTrue);
    expect(actionsOf(st(selectedLane: 2)).contains('music:play-loaded'), isFalse);
    expect(actionsOf(st(directory: true, directoryKind: 'playlist')).contains('music:play-loaded'), isTrue);
    expect(actionsOf(st(directory: true, directoryKind: 'album')).contains('music:play-loaded'), isTrue);
    expect(actionsOf(st(directory: true, directoryKind: 'folder')).contains('music:play-loaded'), isTrue);
    expect(actionsOf(st(directory: true, directoryKind: 'song')).contains('music:play-loaded'), isFalse);
    expect(actionsOf(st(isSiren: true, selectedLane: 3)).contains('music:play-loaded'), isTrue);
    expect(actionsOf(st(isSiren: true, selectedLane: 3)).contains('music:open-all-siren'), isTrue);
    expect(actionsOf(st(isSiren: true, selectedLane: 2)).contains('music:open-all-siren'), isFalse);
  });

  test('play-all y is 319 in directory and 211 otherwise (NativeHud.cpp:423/425)', () {
    final FakeSink a = FakeSink();
    HudArchivePage(a, FakeText()).archive(width: 1920, s: st(directory: true, directoryKind: 'album'),
        drawTrackList: (double w, HudArchiveState x) {}, drawEmpty: (double w, HudArchiveState x) {},
        supportsTrackList: (HudArchiveState x) => false);
    expect(hitOf(a.hits, 'music:play-loaded').y, 319);
    expect(hitOf(a.hits, 'music:parent').y, 211);
    expect(hitOf(a.hits, 'music:directory-info').y, 265);
    final FakeSink b = FakeSink();
    HudArchivePage(b, FakeText()).archive(width: 1920, s: st(selectedLane: 1),
        drawTrackList: (double w, HudArchiveState x) {}, drawEmpty: (double w, HudArchiveState x) {},
        supportsTrackList: (HudArchiveState x) => false);
    expect(hitOf(b.hits, 'music:play-loaded').y, 211);
  });

  test('directory-info label follows directory kind (NativeHud.cpp:412-418)', () {
    String labelFor(String kind) {
      final FakeSink s = FakeSink();
      HudArchivePage(s, FakeText()).archive(width: 1920, s: st(directory: true, directoryKind: kind),
          drawTrackList: (double w, HudArchiveState x) {}, drawEmpty: (double w, HudArchiveState x) {},
          supportsTrackList: (HudArchiveState x) => false);
      return hitOf(s.hits, 'music:directory-info').label;
    }
    expect(labelFor('album'), '查看专辑详情 ↗');
    expect(labelFor('artist'), '查看歌手详情 ↗');
    expect(labelFor('playlist'), '查看歌单详情 ↗');
  });

  test('open control label follows current kind (NativeHud.cpp:444-452)', () {
    final FakeSink s = FakeSink();
    HudArchivePage(s, FakeText()).archive(width: 1920, s: st(currentKind: 'song'),
        drawTrackList: (double w, HudArchiveState x) {}, drawEmpty: (double w, HudArchiveState x) {},
        supportsTrackList: (HudArchiveState x) => false);
    final List<HudHit> opens = s.hits.where((HudHit h) => h.action == 'open').toList();
    expect(opens.length, 2);
    expect(opens.last.label, '查看歌曲详情 →');
    expect(opens.last.y, 703);
    // Qt control() (NativeHud.cpp:121-124) emits hit(x - 10, y, width + 20, 54, action, label).
    expect(opens.last.width, 320);
    expect(opens.first.width, 414);
    expect(opens.first.height, 37);
    expect(opens.first.y, 509);
  });

  test('title/rule/id rows and header dot use Qt geometry (NativeHud.cpp:435-440)', () {
    final FakeSink s = FakeSink();
    HudArchivePage(s, FakeText()).archive(width: 1920, s: st(), drawTrackList: (double w, HudArchiveState x) {},
        drawEmpty: (double w, HudArchiveState x) {}, supportsTrackList: (HudArchiveState x) => false);
    final double x = 1920 - 789;
    expect(textsAt(s.ops, 627).single[1], 'PLAYLIST');
    expect(textsAt(s.ops, 627).single[2], 1920 - 170);
    expect(textsAt(s.ops, 627).single[4], 11);
    expect(textsAt(s.ops, 865).single[1], 'TRACK / SELECT');
    expect(textsAt(s.ops, 865).single[2], 60);
    expect(textsAt(s.ops, 925).single[1], '/');
    expect(textsAt(s.ops, 925).single[2], 141);
    expect(textsAt(s.ops, 925).single[4], 32);
    expect(textsAt(s.ops, 932).single[1], '10');
    expect(textsAt(s.ops, 932).single[2], 172);
    expect(s.ops.where((HudCommand c) => c[0] == 'fill' && c[5] == 6).single[2], x - 12);
    final List<HudCommand> dots = s.ops.where((HudCommand c) => c[0] == 'fill' && c[4] == 6).toList();
    expect(dots.length, 1);
    expect(dots.single[5], 6);
    final List<HudCommand> rules = s.ops.where((HudCommand c) => c[0] == 'fill' && c[5] == 1).toList();
    expect(rules.single[4], 1920 - x - 59);
  });

  test('track number sizing and rolling call (NativeHud.cpp:455-460)', () {
    final FakeSink s = FakeSink();
    final FakeText t = FakeText();
    HudArchivePage(s, t).trackNumber(libraryIndex: 6, libraryTotal: 42);
    expect(t.rolled.single[0], 'music-number');
    expect(t.rolled.single[1], '07');
    expect(t.rolled.single[2], 60);
    expect(t.rolled.single[3], 901.2);
    expect(t.rolled.single[6], 0);
    expect(t.rolled.single[7], true);
    // NativeHud.cpp:457 numberSize = min(58.0, 58.0 * 77 / max(1.0, glyphs->width(number, 58))).
    // FakeText.glyphWidth('07', 58) = 2 * 58 * 0.5 = 58 -> min(58.0, 58 * 77 / 58) = 58.0 exactly,
    // so a constant 58 implementation no longer passes.
    expect(t.rolled.single[4], 58.0);
  });

  test('track number size shrinks for a long number (NativeHud.cpp:457)', () {
    final FakeSink s = FakeSink();
    final FakeText t = FakeText();
    HudArchivePage(s, t).trackNumber(libraryIndex: 999, libraryTotal: 1000);
    expect(t.rolled.single[1], '1000');
    // glyphWidth('1000', 58) = 4 * 58 * 0.5 = 116 -> 58 * 77 / 116 = 38.5, i.e. the min() branch
    // on the right hand side of the Qt expression is what gets selected here.
    expect(t.rolled.single[4], closeTo(58 * 77 / 116, 1e-9));
    expect(t.rolled.single[4], 38.5);
  });

  test('empty delegate runs when current id is empty (NativeHud.cpp:407/461)', () {
    for (final HudArchiveState s0 in <HudArchiveState>[st(emptyCurrent: true), st(currentKind: 'playlist', emptyCurrent: true)]) {
      bool called = false;
      HudArchivePage(FakeSink(), FakeText()).archive(width: 1920, s: s0,
          drawTrackList: (double w, HudArchiveState x) {}, drawEmpty: (double w, HudArchiveState x) { called = true; },
          supportsTrackList: (HudArchiveState x) => false);
      expect(called, isTrue);
    }
  });

  test('hint line text is verbatim for directory and flat (NativeHud.cpp:494)', () {
    final FakeSink a = FakeSink();
    HudArchivePage(a, FakeText()).archive(width: 1920, s: st(directory: true, directoryKind: 'album'),
        drawTrackList: (double w, HudArchiveState x) {}, drawEmpty: (double w, HudArchiveState x) {},
        supportsTrackList: (HudArchiveState x) => false);
    expect(textsAt(a.ops, 850).single[1], '← → 浏览曲目列 / ↑ ↓ 选曲 / ENTER 查看 / ESC 上一级');
    expect(textsAt(a.ops, 850).single[2], 1920 * 0.2625);
    expect(textsAt(a.ops, 850).single[4], 12);
    final FakeSink b = FakeSink();
    HudArchivePage(b, FakeText()).archive(width: 1920, s: st(), drawTrackList: (double w, HudArchiveState x) {},
        drawEmpty: (double w, HudArchiveState x) {}, supportsTrackList: (HudArchiveState x) => false);
    expect(textsAt(b.ops, 850).single[1], '← → 切换来源 / ↑ ↓ 选曲 / ENTER 查看 / 检索');
  });

  test('directory adds back control at 59/211/280 (NativeHud.cpp:410)', () {
    final FakeSink s = FakeSink();
    HudArchivePage(s, FakeText()).archive(width: 1920, s: st(directory: true, directoryKind: 'playlist'),
        drawTrackList: (double w, HudArchiveState x) {}, drawEmpty: (double w, HudArchiveState x) {},
        supportsTrackList: (HudArchiveState x) => false);
    final HudHit back = hitOf(s.hits, 'music:parent');
    expect(back.x, 49);
    expect(back.y, 211);
    expect(back.width, 300);
    expect(back.height, 54);
  });
}