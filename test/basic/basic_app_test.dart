import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rhine_music_database/app/consent_gate.dart';
import 'package:rhine_music_database/basic/basic_models.dart';
import 'package:rhine_music_database/basic/basic_hud.dart';
import 'package:rhine_music_database/ui/pages/consent_page.dart';

SirenSong _song(String id, String title) => SirenSong(
      id: id,
      title: title,
      artist: '塞壬唱片',
      album: '专辑',
      albumId: 'album-1',
      cover: '',
      sourceUrl: 'https://example.invalid/$id.mp3',
      lyricUrl: '',
      durationMs: 180000,
    );

SirenAlbum _album() => SirenAlbum(
      id: 'album-1',
      name: '测试专辑',
      artist: '塞壬唱片',
      cover: '',
      songCount: 2,
      songs: <SirenSong>[_song('s1', '第一首'), _song('s2', '第二首')],
    );

class _FakeConsentPorts implements ConsentPorts {
  ConsentRecord record = const ConsentRecord.empty();
  final List<ConsentRegion> sdkStarts = <ConsentRegion>[];
  int entered = 0;
  int exits = 0;
  int probes = 0;

  @override
  ConsentRecord readRecord() => record;

  @override
  void writeGrant(ConsentRegion region) {
    record = ConsentRecord(granted: true, region: region);
  }

  @override
  Future<ConsentRegion> probeRegion() async {
    probes += 1;
    return ConsentRegion.cn;
  }

  @override
  void startSdks(ConsentRegion region) {
    sdkStarts.add(region);
  }

  @override
  void enterBusiness() {
    entered += 1;
  }

  @override
  void exitApp() {
    exits += 1;
  }
}

void main() {
  group('consent gate', () {
    testWidgets('start -> awaitingConsent -> approve -> proceeded', (WidgetTester tester) async {
      final _FakeConsentPorts ports = _FakeConsentPorts();
      final ConsentGate gate = ConsentGate(ports);

      final Future<void> starting = gate.start();
      expect(gate.phase, ConsentPhase.probing);
      await starting;
      expect(gate.phase, ConsentPhase.awaitingConsent);
      expect(gate.pendingRegion, ConsentRegion.cn);
      expect(ports.probes, 1);
      // 同意未落盘前宿主必须吞掉返回键。
      expect(gate.backPressed(), isFalse);

      gate.approve();
      expect(gate.phase, ConsentPhase.proceeded);
      expect(gate.snapshot.isProceeded, isTrue);
      expect(ports.record.granted, isTrue);
      expect(ports.record.region, ConsentRegion.cn);
      expect(ports.sdkStarts, <ConsentRegion>[ConsentRegion.cn]);
      expect(ports.entered, 1);
      expect(gate.backPressed(), isTrue);
    });

    testWidgets('decline -> terminated and exitApp', (WidgetTester tester) async {
      final _FakeConsentPorts ports = _FakeConsentPorts();
      final ConsentGate gate = ConsentGate(ports);
      await gate.start();
      expect(gate.phase, ConsentPhase.awaitingConsent);

      gate.decline();
      expect(gate.phase, ConsentPhase.terminated);
      expect(ports.exits, 1);
      expect(ports.record.granted, isFalse);
    });

    testWidgets('existing grant skips the dialog', (WidgetTester tester) async {
      final _FakeConsentPorts ports = _FakeConsentPorts()
        ..record = ConsentRecord(granted: true, region: ConsentRegion.cn);
      final ConsentGate gate = ConsentGate(ports);
      await gate.start();
      expect(gate.phase, ConsentPhase.proceeded);
      expect(gate.snapshot.regionProbeCount, 0);
    });

    testWidgets('ConsentPage approves once and reports onProceed', (WidgetTester tester) async {
      final _FakeConsentPorts ports = _FakeConsentPorts();
      final ConsentGate gate = ConsentGate(ports);
      var proceeded = 0;
      await tester.pumpWidget(MaterialApp(
        home: ConsentPage(
          gate: gate,
          businessEntry: BusinessEntryOwner.host,
          onProceed: () => proceeded += 1,
        ),
      ));
      await tester.pumpAndSettle();
      expect(find.text(kCnConsentApprove), findsOneWidget);

      await tester.tap(find.text(kCnConsentApprove));
      await tester.pumpAndSettle();
      expect(gate.snapshot.isProceeded, isTrue);
      expect(proceeded, 1);
    });
  });

  group('library items', () {
    test('albums come before songs and detail shows the album track list', () {
      final BasicViewState library = BasicViewState(
        phase: BasicPhase.library,
        albums: <SirenAlbum>[_album()],
        songs: <SirenSong>[_song('s1', '第一首'), _song('s2', '第二首')],
        catalogLoaded: true,
      );
      final List<BasicListItem> items = basicLibraryItems(library);
      expect(items.map((BasicListItem item) => item.kind).toList(),
          <String>['album', 'song', 'song']);
      expect(items.first.index, 0);

      final BasicViewState detail = library.copyWith(
        phase: BasicPhase.detail,
        album: _album(),
        song: _song('s2', '第二首'),
      );
      final List<BasicListItem> detailItems = basicLibraryItems(detail);
      expect(detailItems.length, 2);
      expect(detailItems.every((BasicListItem item) => item.kind == 'song'), isTrue);
    });

    test('selection follows the playing song when it is in the list', () {
      final BasicViewState state = BasicViewState(
        phase: BasicPhase.library,
        songs: <SirenSong>[_song('s1', '第一首'), _song('s2', '第二首')],
        song: _song('s2', '第二首'),
      );
      final List<BasicListItem> items = basicLibraryItems(state);
      expect(items[basicSelectedItemIndex(state, items)].title, '第二首');
      expect(basicSelectedItemIndex(state, const <BasicListItem>[]), 0);
    });

    test('navigation left matches Qt NativeHud.cpp:408 width - 789', () {
      expect(basicNavigationLeft(1920), 1131);
      expect(basicNavigationLeft(1080), 291);
    });
  });
}
