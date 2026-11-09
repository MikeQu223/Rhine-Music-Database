// T33-C18 A1 (lib/hud/pages/chrome.dart) + A5 (this test file) tests.
// RED/GREEN NOT EXECUTED - execution forbidden by task scope.
import 'package:flutter_test/flutter_test.dart';
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
  // A1 review F7: a constant 0 inset made every 'x - inset' invisible, so the harness now
  // returns a deterministic non-zero inset and the assertions below subtract it explicitly.
  @override
  double glyphInset(String value, double size, [String weight = 'regular']) => value.length * 1.0;
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

void main() {
  test('hudInk returns exact Qt arrays (NativeHud.cpp:10-15)', () {
    expect(hudInk(true), <Object?>[0.92, 0.92, 0.92, 1, 'calibratedWhite']);
    expect(hudInk(false), <Object?>[0.08, 0.085, 0.075, 1, 'calibratedRGB']);
  });

  test('HudHit serialises the six Qt fields in order; fixed is absent unless requested', () {
    const HudHit plain = HudHit(1, 2, 3, 4, 'open', 'title');
    expect(plain.toJson().keys.toList(), <String>['x', 'y', 'width', 'height', 'action', 'label']);
    expect(plain.toJson().containsKey('fixed'), isFalse);
    expect(const HudHit(0, 0, 0, 0, 'a', 'b', fixed: true).toJson()['fixed'], isTrue);
  });

  test('navigationLeft is width - 789 (NativeHud.cpp:342)', () {
    final HudChrome c = HudChrome(FakeSink(), FakeText());
    expect(HudChrome.navigationRightInset, 789);
    expect(c.navigationLeft(1920), 1131);
    expect(HudChrome.stageHeight, 1080);
    expect(HudChrome.maskClipHeight, 984);
    expect(HudChrome.archiveMaskFadeWidth, 300);
    expect(HudChrome.defaultArchiveMaskStrength, 50);
  });

  test('archiveMask: save/clip/right-mask/restore, FadeWidth 300, height 984, opacity strength/100', () {
    final FakeSink s = FakeSink();
    // A1 review F10: dark now comes from the instance (NativeHud.h:140), not from a parameter.
    HudChrome(s, FakeText(), dark: true).archiveMask(width: 1920, strength: 50);
    expect(s.ops.length, 4);
    expect(s.ops[0], <Object?>['save']);
    expect(s.ops[1], <Object?>['clip', 0, 0, 1920, 984]);
    final HudCommand m = s.ops[2];
    expect(m[0], 'right-mask');
    expect(m[2], 1920 - 789 - 300);
    expect(m[3], 300);
    expect(m[4], 1920);
    expect(m[5], 984);
    expect((m[1] as List<Object?>)[3], 0.5);
    expect(s.ops[3], <Object?>['restore']);
  });

  test('archiveMask strength 0 emits nothing (NativeHud.cpp:314)', () {
    final FakeSink s = FakeSink();
    HudChrome(s, FakeText()).archiveMask(width: 1920, strength: 0);
    expect(s.ops, isEmpty);
  });

  test('archiveMask light palette (NativeHud.cpp:320)', () {
    final FakeSink s = FakeSink();
    HudChrome(s, FakeText()).archiveMask(width: 1000, strength: 100);
    expect((s.ops[2][1] as List<Object?>).sublist(0, 3), <Object?>[0.9, 0.89, 0.86]);
    expect((s.ops[2][1] as List<Object?>)[3], 1.0);
  });

  test('brandLine text commands are exact (NativeHud.cpp:332-341)', () {
    final FakeSink s0 = FakeSink();
    HudChrome(s0, FakeText()).brandLine(0);
    expect(s0.ops.single.sublist(0, 7), <Object?>['text', 'RHINE LAB', 59, 115.425, 50.75, 'bold', 1]);
    final FakeSink s1 = FakeSink();
    HudChrome(s1, FakeText()).brandLine(1);
    expect(s1.ops.single.sublist(0, 7), <Object?>['text', 'MUSIC DATABASE', 59, 169, 22, 'demibold', 1.7]);
    final FakeSink s2 = FakeSink();
    HudChrome(s2, FakeText()).brandLine(2);
    expect(s2.ops[0][0], 'fill');
    expect(s2.ops[0].sublist(2, 6), <Object?>[59, 212, 300, 1]);
    // A1 review F1: brandLine(2) calls hudRule with the instance dark (false by default,
    // NativeHud.h:140) at opacity 0.65 (NativeHud.cpp:338), so the colour is the calibratedRGB
    // ink with alpha replaced, never calibratedWhite.
    expect(s2.ops[0][1], <Object?>[0.08, 0.085, 0.075, 0.65, 'calibratedRGB']);
    expect(s2.ops[1].sublist(0, 7), <Object?>['text', 'INDEX / COLLECTION / TRACK', 59, 228, 11, 'regular', 1.2]);
  });

  test('brand rolls music-brand at 59/115.425/44/bold (NativeHud.cpp:329)', () {
    final FakeText t = FakeText();
    HudChrome(FakeSink(), t).brand(libraryName: 'LIB', width: 2000);
    expect(t.rolled.length, 1);
    expect(t.rolled.single[0], 'music-brand');
    expect(t.rolled.single[1], 'LIB');
    expect(t.rolled.single[2], 59 - 'LIB'.length * 1.0); // :100 x - glyphInset(shown, 44, 'bold')
    expect(t.rolled.single[3], 115.425);
    expect(t.rolled.single[4], 44);
    expect(t.rolled.single[5], 'bold');
  });

  test('navigation hit rects and actions (NativeHud.cpp:345-356)', () {
    final FakeSink s = FakeSink();
    HudChrome(s, FakeText()).navigation(width: 1920, isLocal: false, isSiren: false, updaterAvailable: false);
    expect(s.hits.map((HudHit h) => h.action).toList(), <String>['discover', 'search', 'saved', 'settings']);
    final double x = 1920 - 789 + 210;
    expect(s.hits[0].x, x - 210 - 10);
    expect(s.hits[0].y, 118);
    expect(s.hits[0].width, 204);
    expect(s.hits[0].height, 54);
    expect(s.hits[2].x, x + 200 - 10);
    expect(s.hits[2].width, 204);
    expect(s.hits[3].x, x + 400 - 10);
    expect(s.hits[3].width, 140);
    expect(s.hits[0].label, '发现音乐 ↗');
    expect(s.hits[1].label, '音乐检索  /');
    expect(s.hits[2].label, '＋ 我的音乐');
    expect(s.hits[3].label, '设置');
  });

  test('navigation local/siren labels and updater label (NativeHud.cpp:347-355)', () {
    final FakeSink a = FakeSink();
    HudChrome(a, FakeText()).navigation(width: 1920, isLocal: true, isSiren: false, updaterAvailable: true);
    expect(a.hits[0].label, '文件夹管理 ＋');
    expect(a.hits[2].label, '本地曲库');
    expect(a.hits[3].label, '设置 · 更新');
    final FakeSink b = FakeSink();
    HudChrome(b, FakeText()).navigation(width: 1920, isLocal: false, isSiren: true, updaterAvailable: false);
    // A1 review F2: Qt :347 fires discover when isLocal(), :349 only when !isSiren(); for a siren
    // guest neither branch runs, so the row is [search, saved, settings] with no discover entry.
    expect(b.hits.map((HudHit h) => h.action).toList(), <String>['search', 'saved', 'settings']);
    expect(b.hits[0].label, '音乐检索  /');
    expect(b.hits[1].label, '＋ 塞壬曲库');
    expect(b.hits[2].label, '设置');
  });

  test('footer session label mapping (NativeHud.cpp:357-373)', () {
    List<List<Object?>> rows = <List<Object?>>[
      <Object?>[true, false, '', 'netease', 'LOCAL LIBRARY'],
      <Object?>[false, false, '', 'netease', 'GUEST SESSION'],
      <Object?>[false, true, '', 'netease', 'SIREN RECORDS'],
      <Object?>[false, false, 'u1', 'netease', 'NETEASE SESSION'],
      <Object?>[false, false, 'u1', 'qq', 'QQ SESSION'],
      <Object?>[false, false, 'u1', 'kugou', 'KUGOU SESSION'],
    ];
    for (final List<Object?> row in rows) {
      final FakeSink s = FakeSink();
      HudChrome(s, FakeText()).footer(width: 1920, isLocal: row[0] as bool, isSiren: row[1] as bool, uid: row[2] as String, provider: row[3] as String);
      expect(s.ops.first, <Object?>['fill', <Object?>[119.0 / 255, 123.0 / 255, 96.0 / 255, 1], 59, 971, 5, 5]);
      final HudCommand t = s.ops[1];
      expect(t[0], 'text');
      expect(t[1], row[4] as String);
      expect(t[2], 75);
      expect(t[3], 967);
      expect(t[4], 10);
      expect(t[6], 0.9);
      final HudCommand credit = s.ops.last;
      expect(credit[1], 'POWERED BY RHINE LAB');
      expect(credit[4], 10);
      // A1 review F8: NativeHud.cpp:372 places the credit at width - 59 - glyphs->width(credit, 10,
      // 'demibold'), the only glyphWidth driven layout inside chrome.
      expect(credit[2], 1920 - 59 - 'POWERED BY RHINE LAB'.length * 10 * 0.5);
      expect(credit[5], 'demibold');
    }
  });

  test('chromeView emission order: mask -> brand -> navigation -> footer (NativeHud.cpp:267-311)', () {
    final FakeSink s = FakeSink();
    HudChrome(s, FakeText()).chromeView(width: 1920, archiveMode: true, suppressMask: false, libraryName: 'LIB',
        isLocal: true, isSiren: false, uid: 'u1', provider: 'netease', archiveMaskStrength: 50, updaterAvailable: false);
    expect(s.ops[0][0], 'save');
    expect(s.ops[1][0], 'clip');
    expect(s.ops[2][0], 'right-mask');
    expect(s.ops[3][0], 'restore');
    expect(s.hits.map((HudHit h) => h.action).toList(), <String>['discover', 'search', 'saved', 'settings']);
    // A1 review F5: NativeHud.cpp:275-277 fixes the order brand -> navigation -> footer. The brand
    // line is the first text command, the four navigation controls sit at y 132 and the footer
    // credit is the last text command, so swapping any two sections fails here.
    final List<HudCommand> texts = s.ops.where((HudCommand c) => c[0] == 'text').toList();
    expect(texts.first[1], 'RHINE LAB / MUSIC DATABASE');
    expect(texts.first[3], 173);
    expect(texts.where((HudCommand c) => c[3] == 132).length, 4);
    expect(texts.last[1], 'POWERED BY RHINE LAB');
    expect(texts.last[3], 967);
    final int searchAt = s.ops.indexWhere((HudCommand c) => c[1] == '音乐检索  /');
    final int footerSwatch = s.ops.indexWhere((HudCommand c) => c[0] == 'fill' && c[4] == 5 && c[5] == 5);
    expect(footerSwatch, greaterThan(searchAt));
  });

  test('chromeView suppresses mask outside archive mode or when suppressed', () {
    final FakeSink s = FakeSink();
    HudChrome(s, FakeText()).chromeView(width: 1920, archiveMode: false, suppressMask: false, libraryName: 'LIB',
        isLocal: true, isSiren: false, uid: '', provider: 'netease', archiveMaskStrength: 50, updaterAvailable: false);
    expect(s.ops.any((HudCommand c) => c[0] == 'right-mask'), isFalse);
    // A1 review F6: NativeHud.cpp:272 also skips the mask when the caller reports suppression
    // (the Qt condition is !(lyricsMode && !player.current.isEmpty())). The rest of the chrome
    // band must still be emitted.
    final FakeSink t = FakeSink();
    HudChrome(t, FakeText()).chromeView(width: 1920, archiveMode: true, suppressMask: true, libraryName: 'LIB',
        isLocal: true, isSiren: false, uid: 'u1', provider: 'netease', archiveMaskStrength: 50, updaterAvailable: false);
    expect(t.ops.any((HudCommand c) => c[0] == 'right-mask'), isFalse);
    expect(t.ops.any((HudCommand c) => c[0] == 'save'), isFalse);
    expect(t.ops.any((HudCommand c) => c[0] == 'clip'), isFalse);
    expect(t.hits.map((HudHit h) => h.action).toList(), <String>['discover', 'search', 'saved', 'settings']);
    expect(t.ops.where((HudCommand c) => c[0] == 'text').first[1], 'RHINE LAB / MUSIC DATABASE');
    expect(t.ops.where((HudCommand c) => c[0] == 'text').last[1], 'POWERED BY RHINE LAB');
  });

  test('hudControl emits hit then aligned text at y+14 size 20 demibold (NativeHud.cpp:121-124)', () {
    final FakeSink s = FakeSink();
    hudControl(s, FakeText(), '音乐检索  /', 100, 118, 184, 'search');
    expect(s.hits.single.action, 'search');
    expect(s.hits.single.x, 90);
    expect(s.hits.single.width, 204);
    expect(s.hits.single.height, 54);
    // A1 review F7: aligned() subtracts glyphInset (:45), which the harness now makes non-zero.
    expect(s.ops.single.sublist(0, 2), <Object?>['text', '音乐检索  /']);
    expect(s.ops.single[2], 100 - '音乐检索  /'.length * 1.0);
    expect(s.ops.single.sublist(3, 7), <Object?>[132, 20, 'demibold', 0]);
  });

  test('hudRule emits a 1px fill with ink alpha replaced by opacity (NativeHud.cpp:125-129)', () {
    final FakeSink s = FakeSink();
    hudRule(s, true, 59, 212, 300, 0.65);
    expect(s.ops.single, <Object?>['fill', <Object?>[0.92, 0.92, 0.92, 0.65, 'calibratedWhite'], 59, 212, 300, 1]);
  });
}