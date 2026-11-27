// T33-C18 A3 (lib/hud/pages/directory_empty.dart) + A5 (this test file) tests.
// RED/GREEN NOT EXECUTED - execution forbidden by task scope.
import 'package:flutter_test/flutter_test.dart';
import 'package:rhine_music_database/hud/pages/chrome.dart';
import 'package:rhine_music_database/hud/pages/directory_empty.dart';

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

HudDirectoryEmptyState es({
  String libraryName = 'LIB',
  int selectedLane = 0,
  bool isLocal = true,
  bool isSiren = false,
  String uid = 'u1',
  bool restoringAccount = false,
  bool sourceLoading = false,
  String providerName = '网易云',
  bool directory = false,
  String? directoryStatus,
  String? sourceMessage,
}) =>
    HudDirectoryEmptyState(
      libraryName: libraryName,
      selectedLane: selectedLane,
      isLocal: isLocal,
      isSiren: isSiren,
      uid: uid,
      restoringAccount: restoringAccount,
      sourceLoading: sourceLoading,
      providerName: providerName,
      directory: directory,
      directoryStatus: directoryStatus,
      sourceMessage: sourceMessage,
    );

FakeSink render(HudDirectoryEmptyState s) {
  final FakeSink sink = FakeSink();
  HudDirectoryEmpty(sink, FakeText()).empty(width: 1920, s: s);
  return sink;
}

void main() {
  test('default branch is search / 音乐资料库 (NativeHud.cpp:381-383)', () {
    final FakeSink s = render(es());
    expect(s.hits.single.action, 'search');
    expect(s.hits.single.label, '检索音乐 →');
    // Qt button() (NativeHud.cpp:110-119) emits hit(x, y, width, height, ...) with no padding
    // because archive/library never sets m_modalControls (NativeHud.h:222 default false).
    expect(s.hits.single.x, 1920 - 789);
    expect(s.hits.single.y, 703);
    expect(s.hits.single.width, 300);
    expect(s.hits.single.height, 32);
    expect(textsAt(s.ops, 509).single[1], '音乐资料库');
    expect(textsAt(s.ops, 509).single[4], 28);
  });

  test('directory branch adds back control and歌单 label (NativeHud.cpp:377/384)', () {
    final FakeSink s = render(es(directory: true, libraryName: 'DIR'));
    expect(s.hits.length, 2);
    expect(s.hits.first.action, 'music:parent');
    expect(s.hits.first.x, 49);
    expect(s.hits.first.y, 211);
    expect(s.hits.first.width, 300);
    expect(s.hits.last.action, 'music:directory-info');
    expect(s.hits.last.label, '查看歌单详情 →');
    expect(textsAt(s.ops, 509).single[1], 'DIR');
  });

  test('lane>0 saved branch, siren vs normal label (NativeHud.cpp:388-391)', () {
    final FakeSink n = render(es(selectedLane: 2));
    expect(n.hits.single.action, 'saved');
    expect(n.hits.single.label, '查看我的音乐 →');
    final FakeSink r = render(es(selectedLane: 2, isSiren: true));
    expect(r.hits.single.label, '查看曲库 →');
  });

  test('login branch overrides title and label (NativeHud.cpp:392-393)', () {
    // A3 review F1: Qt's override (:392) requires !music.isLocal() first, and es() defaults
    // isLocal to true, so the old call silently stayed on the saved branch and this test could
    // never pass. The non-local condition is now explicit.
    final FakeSink s = render(es(selectedLane: 2, isLocal: false, uid: '', providerName: '网易云'));
    expect(s.hits.single.action, 'music:login');
    expect(s.hits.single.label, '登录网易云 →');
    expect(textsAt(s.ops, 509).single[1], '登录后查看');
  });

  test('login branch needs non-local, non-siren, empty uid, not restoring (NativeHud.cpp:392)', () {
    // Qt :392 is one conjunction: !isLocal && !isSiren && uid.isEmpty() && !restoringAccount.
    // Each conjunct is denied on its own here, so a wrong operator in any position is visible.
    expect(render(es(selectedLane: 2, isLocal: true, uid: '')).hits.single.action, 'saved');
    expect(render(es(selectedLane: 2, isLocal: false, isSiren: true, uid: '')).hits.single.action, 'saved');
    expect(render(es(selectedLane: 2, isLocal: false, restoringAccount: true, uid: '')).hits.single.action, 'saved');
    expect(render(es(selectedLane: 2, isLocal: false, uid: 'u1')).hits.single.action, 'saved');
    // and the full conjunction does flip to the login branch
    expect(render(es(selectedLane: 2, isLocal: false, uid: '')).hits.single.action, 'music:login');
  });

  test('source loading title (NativeHud.cpp:389)', () {
    final FakeSink s = render(es(selectedLane: 1, sourceLoading: true));
    expect(textsAt(s.ops, 509).single[1], '正在同步音乐资料…');
  });

  test('geometry: x = width-789, caption widths, rule row (NativeHud.cpp:375/398-402)', () {
    final FakeSink s = render(es(selectedLane: 1, sourceMessage: 'MSG'));
    final double x = 1920 - 789;
    expect(textsAt(s.ops, 471).single[1], 'MUSIC DATABASE / LIB');
    expect(textsAt(s.ops, 471).single[2], x);
    expect(textsAt(s.ops, 471).single[4], 12);
    expect(textsAt(s.ops, 509).single[2], x);
    expect(textsAt(s.ops, 624).single[1], 'MSG');
    expect(textsAt(s.ops, 624).single[2], x);
    expect(textsAt(s.ops, 624).single[4], 16);
    final List<HudWireCommand> rules = s.ops.where((HudWireCommand c) => c[0] == 'fill' && c[5] == 1).toList();
    expect(rules.single[4], 1920 - x - 59);
    expect(rules.single[2], x);
    expect(rules.single[3], 601);
    // A3 review F3: Qt omits the opacity argument at :399 and relies on NativeHud.h:261's 0.4
    // default. The exact 5 element colour pins the ink base, the replaced alpha and the marker.
    expect(rules.single[1], <Object?>[0.08, 0.085, 0.075, 0.4, 'calibratedRGB']);
    // :398 limited(..., "bold") -> the title carries weight 'bold' (text slot 5).
    expect(textsAt(s.ops, 509).single[5], 'bold');
  });

  test('back control hit and aligned label (NativeHud.cpp:121-124/378)', () {
    final FakeSink s = render(es(directory: true));
    final HudHit h = s.hits.first;
    expect(h.action, 'music:parent');
    expect(h.x, 49);
    expect(h.y, 211);
    expect(h.width, 300);
    // A3 review F4: control() hit rect is x-10 / width+20 / height 54 (NativeHud.cpp:122).
    expect(h.height, 54);
    // and its label is aligned at x, y+14, size 20, demibold (:123).
    final HudWireCommand label = textsAt(s.ops, 211 + 14).single;
    expect(label[1], '← 返回上一级');
    expect(label[2], 59);
    expect(label[4], 20);
    expect(label[5], 'demibold');
  });

  test('emission order is control, caption, title, rule, description, button hit, button label (NativeHud.cpp:377-402)', () {
    final FakeSink s = render(es(directory: true));
    // A3 review F4: the Qt order is a semantic, not an implementation detail. Commands and hits are
    // two separate outlets, so the command stream is six entries and the two button hits are
    // asserted on the hit outlet; control() still emits its hit before its aligned label (:122/:123).
    expect(s.ops.map((HudWireCommand c) => c[0]).toList(), <String>['text', 'text', 'text', 'fill', 'text', 'text']);
    expect(s.ops[0][1], '← 返回上一级');
    expect(s.ops[1][1], 'MUSIC DATABASE / LIB');
    expect(s.ops[2][1], 'LIB');
    expect(s.ops[3][0], 'fill');
    expect((s.ops[3][1] as List<Object?>)[3], 0.4);
    expect(s.ops[5][1], '查看歌单详情 →');
    expect(s.hits.map((HudHit h) => h.action).toList(), <String>['music:parent', 'music:directory-info']);
  });

  test('directory uses directoryStatus for the caption (NativeHud.cpp:400)', () {
    final FakeSink s = render(es(directory: true, directoryStatus: 'ST'));
    expect(textsAt(s.ops, 624).single[1], 'ST');
  });
}