// T26-V3 storage integration tests: Qt session.json restore semantics.
// Spec: T07 FROZEN on-disk contract (/tmp/t07-drafts/storage.md) + Qt/src/MusicSession.cpp,
// Qt/src/NativeApplication.cpp, Qt/src/MusicPlayer.cpp at baseline 8ed3067.
// STATIC ONLY: written but NEVER executed in this stage (no flutter/dart test run allowed).

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:rhine_music_database/data/storage/app_storage.dart';
import 'package:rhine_music_database/data/storage/playback_store.dart';
import 'package:rhine_music_database/data/storage/session_store.dart';

void main() {
  late Directory temp;
  late AppStorage storage;
  late SessionStore store;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('t26_session_');
    storage = AppStorage(
      paths: AppStoragePaths(
        dataDirectory: temp.path,
        cacheDirectory: temp.path + '/cache',
        temporaryDirectory: temp.path + '/tmp',
        executableDirectory: temp.path + '/exe',
      ),
    );
    // settingsScrollMaximum is a RUNTIME LAYOUT FUNCTION in Qt (NativeHud.h:115-135),
    // never a constant; the store must clamp a saved value against it.
    store = SessionStore(storage: storage, settingsScrollMaximum: () => 660);
  });

  tearDown(() {
    if (temp.existsSync()) {
      temp.deleteSync(recursive: true);
    }
  });

  const SessionIdentity identity =
      SessionIdentity(provider: 'netease', edition: 'standard', uid: 'u1');

  Map<String, Object?> lane() => <String, Object?>{
        'items': <Object?>[],
        'total': 0,
        'offset': 0,
        'more': false,
        'row': 0,
      };

  Map<String, Object?> directory({
    Object? index = 0,
    Object? page = -1,
    Object? sortField = 'none',
    List<Object?>? songs,
  }) =>
      <String, Object?>{
        'item': <String, Object?>{},
        'songs': songs ?? <Object?>[],
        'ids': <Object?>[],
        'albums': <Object?>[],
        'sortField': sortField,
        'cursor': 0,
        'index': index,
        'anchor': 0,
        'page': page,
        'parentPhysical': 0,
        'parentLane': 0,
        'parentItem': <String, Object?>{},
        'albumCursor': 0,
        'albumsMore': false,
      };

  Map<String, Object?> libraryJson({
    String provider = 'netease',
    String edition = 'standard',
    String uid = 'u1',
    int lanes = 5,
    List<Object?>? directories,
    Object? selectedPhysical = -1,
    int selectedLane = 0,
    Object? current,
  }) =>
      <String, Object?>{
        'provider': provider,
        'edition': edition,
        'uid': uid,
        'sources': List<Object?>.generate(lanes, (int i) => lane()),
        'directories': directories ?? <Object?>[],
        'current': current ?? <String, Object?>{},
        'selectedPhysical': selectedPhysical,
        'selectedLane': selectedLane,
      };

  Map<String, Object?> playerJson({
    Map<String, Object?>? current,
    List<Object?>? queue,
    Object? index = -1,
    Object? mode = 'all',
    Object? position = 0.0,
    Object? requested = false,
  }) =>
      <String, Object?>{
        'current': current ?? <String, Object?>{},
        'queue': queue ?? <Object?>[],
        'index': index,
        'mode': mode,
        'position': position,
        'requested': requested,
        'preview': false,
      };

  Map<String, Object?> viewJson({Map<String, Object?> overrides = const <String, Object?>{}}) {
    final Map<String, Object?> base = <String, Object?>{
      'mode': 'archive',
      'selected': 0,
      'tab': 'overview',
      'modal': '',
      'queueOffset': 0,
      'settingsScroll': 0.0,
      'query': '',
      'groupBy': 'none',
      'activeGroup': '',
      'artistTab': 'songs',
      'listOffset': 0,
      'trackOffset': 0,
      'bodyOffset': 0,
      'musicCollection': 1,
      'trackListMode': false,
      'lyricsMode': false,
    };
    base.addAll(overrides);
    return base;
  }

  Map<String, Object?> sessionJson({
    Map<String, Object?>? library,
    Map<String, Object?>? view,
    Map<String, Object?>? player,
    Object? version = 1,
  }) =>
      <String, Object?>{
        'version': version,
        'library': library ?? libraryJson(),
        'player': player ?? playerJson(),
        'view': view ?? viewJson(),
      };

  Future<void> writeSession(Map<String, Object?> value) async {
    await File(storage.sessionPath).writeAsString(jsonEncode(value));
  }

  Future<SessionRestoreResult> load({bool playbackConnection = false}) =>
      store.loadForRestore(identity, playbackConnection: playbackConnection);

  group('T26-S02 session restore gate (Qt/src/NativeApplication.cpp:44-75, :237-240)', () {
    test('a complete session restores library, view and player', () async {
      await writeSession(sessionJson());
      final SessionRestoreResult r = await load();
      expect(r.loaded, isTrue);
      expect(r.failureReason, isNull);
      expect(r.library, isNotNull);
      expect(r.view, isNotNull);
      expect(r.player, isNotNull);
    });

    test('version other than 1 fails and keeps the file', () async {
      await writeSession(sessionJson(version: 2));
      final SessionRestoreResult r = await load();
      expect(r.loaded, isFalse);
      expect(r.failureReason, 'version');
      expect(r.view, isNull);
      expect(r.player, isNull);
      expect(File(storage.sessionPath).existsSync(), isTrue);
    });

    test('provider mismatch fails the WHOLE library and keeps the file', () async {
      await writeSession(sessionJson(library: libraryJson(provider: 'kugou')));
      final SessionRestoreResult r = await load();
      expect(r.loaded, isFalse);
      expect(r.failureReason, 'provider-mismatch');
      expect(File(storage.sessionPath).existsSync(), isTrue);
    });

    test('kugou edition mismatch fails (standard vs lite)', () async {
      await writeSession(sessionJson(library: libraryJson(edition: 'lite')));
      final SessionRestoreResult r = await load();
      expect(r.loaded, isFalse);
      expect(r.failureReason, 'edition-mismatch');
    });

    test('uid mismatch fails: an empty account-id must not restore an authenticated session', () async {
      await writeSession(sessionJson(library: libraryJson(uid: 'someone-else')));
      final SessionRestoreResult r = await load();
      expect(r.loaded, isFalse);
      expect(r.failureReason, 'uid-mismatch');
    });

    test('sources must be exactly 5 lanes', () async {
      await writeSession(sessionJson(library: libraryJson(lanes: 4)));
      final SessionRestoreResult r = await load();
      expect(r.loaded, isFalse);
      expect(r.failureReason, 'sources-length');
    });

    test('at most 64 directory levels', () async {
      final List<Object?> sixtyFive = List<Object?>.generate(65, (int i) => directory());
      await writeSession(sessionJson(library: libraryJson(directories: sixtyFive)));
      final SessionRestoreResult r = await load();
      expect(r.loaded, isFalse);
      expect(r.failureReason, 'directories-too-many');
    });

    test('selectedPhysical outside -1..39 fails', () async {
      await writeSession(sessionJson(library: libraryJson(selectedPhysical: 40)));
      final SessionRestoreResult r = await load();
      expect(r.loaded, isFalse);
      expect(r.failureReason, 'selected-physical');
    });

    test('selectedPhysical >= 0 must belong to physicalSlots[selectedLane] (empty lane -> not a slot)', () async {
      // Qt checks physicalSlots membership (Qt/src/MusicSession.cpp:92-98) against
      // the runtime slot layout built by MusicLibrary.cpp:50-58. The layout is an
      // injected runtime input, so this test injects one whose lane 0 is empty.
      final SessionStore slotAware = SessionStore(
        storage: storage,
        settingsScrollMaximum: () => 660,
        physicalSlots: SessionStore.derivePhysicalSlots(<String, Object?>{
          'columns': <Object?>['a', 'b', 'c', 'd', 'e'],
          'records': <Object?>[],
        }),
      );
      await writeSession(sessionJson(library: libraryJson(selectedPhysical: 0, selectedLane: 0)));
      final SessionRestoreResult r =
          await slotAware.loadForRestore(identity, playbackConnection: false);
      expect(r.loaded, isFalse);
      expect(r.failureReason, 'selected-physical');
    });

    test('selectedPhysical >= 0 that belongs to physicalSlots[selectedLane] restores', () async {
      final SessionStore slotAware = SessionStore(
        storage: storage,
        settingsScrollMaximum: () => 660,
        physicalSlots: SessionStore.derivePhysicalSlots(<String, Object?>{
          'columns': <Object?>['a', 'b', 'c', 'd', 'e'],
          'records': <Object?>[
            <String, Object?>{'category': 'a'},
          ],
        }),
      );
      await writeSession(sessionJson(library: libraryJson(selectedPhysical: 0, selectedLane: 0)));
      final SessionRestoreResult r =
          await slotAware.loadForRestore(identity, playbackConnection: false);
      expect(r.loaded, isTrue);
      expect(r.library!['selectedPhysical'], 0);
      expect(r.library!['selectedLane'], 0);
    });

    test('directory page is ignored on read and recomputed as index/40*40', () async {
      // Qt clamps the restored index to max(0, songs.size() - 1)
      // (Qt/src/MusicSession.cpp:128) and then recomputes page = index / 40 * 40 (:130),
      // so the fixture needs 84 rows for index 83 to survive and yield page 80.
      final List<Object?> songs =
          List<Object?>.generate(84, (int i) => <String, Object?>{'id': 's' + i.toString()});
      await writeSession(sessionJson(
        library: libraryJson(
          directories: <Object?>[directory(index: 83, page: 999, songs: songs)],
        ),
      ));
      final SessionRestoreResult r = await load();
      expect(r.loaded, isTrue);
      final List<Object?> dirs = r.library!['directories']! as List<Object?>;
      final Map<String, Object?> first = dirs.first! as Map<String, Object?>;
      expect(first['index'], 83);
      expect(first['page'], 80);
    });

    test('sortField outside none/title/album/artist falls back to none', () async {
      await writeSession(sessionJson(
        library: libraryJson(directories: <Object?>[directory(sortField: 'bogus')]),
      ));
      final SessionRestoreResult r = await load();
      final List<Object?> dirs = r.library!['directories']! as List<Object?>;
      expect((dirs.first! as Map<String, Object?>)['sortField'], 'none');
    });

    test('the player is NOT restored while a background playback connection exists', () async {
      await writeSession(sessionJson());
      final SessionRestoreResult r = await load(playbackConnection: true);
      expect(r.loaded, isTrue);
      expect(r.player, isNull);
      expect(r.view, isNotNull);
    });

    test('no rejected session ever logs out or drops collections (T07 0.2, plan T26 Fail)', () async {
      // Plan T26 Fail condition is "默认登出或丢收藏": a parse failure or a failed
      // identity gate must leave the archive, the account credential, the siren
      // collections and both device identity files exactly as they were. Only an
      // explicit sign-out may touch credentials (T07 0.2 and 6.5; T07 line 403
      // fixes two device files: qq-device.json and kugou-device.json).
      const String credential = '{"netease":{"uid":"u1"}}';
      const String siren = '{"songs":[{"id":"t1"}]}';
      const String device = '{"device":"kugou-1"}';
      const String qqDevice = '{"device":"qq-1"}';
      await File(storage.credentialPath).writeAsString(credential);
      await Directory(storage.collectionsDirectory).create(recursive: true);
      await File(storage.sirenCollectionPath).writeAsString(siren);
      await File(storage.kugouDevicePath).writeAsString(device);
      await File(storage.qqDevicePath).writeAsString(qqDevice);

      final List<Map<String, String>> rejected = <Map<String, String>>[
        <String, String>{
          'body': jsonEncode(sessionJson()).substring(0, 40),
          'reason': 'invalid-json',
        },
        <String, String>{
          'body': jsonEncode(sessionJson(version: 2)),
          'reason': 'version',
        },
        <String, String>{
          'body': jsonEncode(sessionJson(library: libraryJson(provider: 'kugou'))),
          'reason': 'provider-mismatch',
        },
      ];
      for (final Map<String, String> entry in rejected) {
        final String body = entry['body']!;
        await File(storage.sessionPath).writeAsString(body);
        final SessionRestoreResult r = await load();
        expect(r.loaded, isFalse, reason: entry['reason']);
        expect(r.failureReason, entry['reason']);
        expect(r.library, isNull);
        expect(r.view, isNull);
        expect(r.player, isNull);
        // The archive keeps every byte it had ...
        expect(await File(storage.sessionPath).readAsString(), body, reason: entry['reason']);
        // ... and the account / favourites / device identity survive untouched.
        expect(await File(storage.credentialPath).readAsString(), credential, reason: entry['reason']);
        expect(await File(storage.sirenCollectionPath).readAsString(), siren, reason: entry['reason']);
        expect(await File(storage.kugouDevicePath).readAsString(), device, reason: entry['reason']);
        expect(await File(storage.qqDevicePath).readAsString(), qqDevice, reason: entry['reason']);
        expect(File(storage.credentialPath).existsSync(), isTrue, reason: entry['reason']);
      }
    });
  });

  group('T26-S02 view normalisation (Qt/src/MusicSession.cpp:215-267)', () {
    test('toJson emits exactly the 16 contract keys in order', () async {
      await writeSession(sessionJson());
      final SessionRestoreResult r = await load();
      expect(r.view!.toJson().keys.toList(), <String>[
        'mode',
        'selected',
        'tab',
        'modal',
        'queueOffset',
        'settingsScroll',
        'query',
        'groupBy',
        'activeGroup',
        'artistTab',
        'listOffset',
        'trackOffset',
        'bodyOffset',
        'musicCollection',
        'trackListMode',
        'lyricsMode',
      ]);
    });

    test('unknown view fields are ignored on read and never written back', () async {
      final Map<String, Object?> raw = viewJson();
      raw['notARealField'] = 'x';
      raw['another'] = 1;
      await writeSession(sessionJson(view: raw));
      final SessionRestoreResult r = await load();
      expect(r.view!.toJson().containsKey('notARealField'), isFalse);
      expect(r.view!.toJson().containsKey('another'), isFalse);
    });

    test('modal only accepts the seven real modals, everything else becomes empty', () async {
      for (final String ok in <String>[
        'saved',
        'search',
        'discover',
        'queue',
        'settings',
        'player',
        'local',
      ]) {
        await writeSession(sessionJson(view: viewJson(overrides: <String, Object?>{'modal': ok})));
        final SessionRestoreResult r = await load();
        expect(r.view!.toJson()['modal'], ok);
      }
      for (final Object? bad in <Object?>['bogus', '', null, 7]) {
        await writeSession(sessionJson(view: viewJson(overrides: <String, Object?>{'modal': bad})));
        final SessionRestoreResult r = await load();
        expect(r.view!.toJson()['modal'], '');
      }
    });

    test('mode detail requires a non-empty library.current, otherwise archive', () async {
      await writeSession(sessionJson(view: viewJson(overrides: <String, Object?>{'mode': 'detail'})));
      expect((await load()).view!.toJson()['mode'], 'archive');

      await writeSession(sessionJson(
        library: libraryJson(current: <String, Object?>{'id': 't1', 'kind': 'song'}),
        view: viewJson(overrides: <String, Object?>{'mode': 'detail'}),
      ));
      expect((await load()).view!.toJson()['mode'], 'detail');
    });

    test('tab whitelist and numeric clamps', () async {
      await writeSession(sessionJson(view: viewJson(overrides: <String, Object?>{
        'tab': 'bogus',
        'selected': 99,
        'musicCollection': 0,
        'settingsScroll': 99999.0,
        'queueOffset': -5,
        'listOffset': -1,
        'trackOffset': -1,
        'bodyOffset': -1,
        'trackListMode': 'yes',
        'lyricsMode': 3,
      })));
      final Map<String, Object?> v = (await load()).view!.toJson();
      expect(v['tab'], 'overview');
      expect(v['selected'], 39);
      expect(v['musicCollection'], 1);
      expect(v['settingsScroll'], 660);
      expect(v['queueOffset'], 0);
      expect(v['listOffset'], 0);
      expect(v['trackOffset'], 0);
      expect(v['bodyOffset'], 0);
      expect(v['trackListMode'], isFalse);
      expect(v['lyricsMode'], isFalse);
    });

    test('string defaults: query, groupBy, activeGroup, artistTab', () async {
      await writeSession(sessionJson(view: viewJson(overrides: <String, Object?>{
        'query': 5,
        'groupBy': 5,
        'activeGroup': 5,
        'artistTab': 5,
      })));
      final Map<String, Object?> v = (await load()).view!.toJson();
      expect(v['query'], '');
      expect(v['groupBy'], 'none');
      expect(v['activeGroup'], '');
      expect(v['artistTab'], 'songs');
    });

    test('an empty groupBy string is preserved, not defaulted', () async {
      await writeSession(sessionJson(view: viewJson(overrides: <String, Object?>{'groupBy': ''})));
      expect((await load()).view!.toJson()['groupBy'], '');
    });
  });

  group('T26-S03 player inside session.json (Qt/src/MusicPlayer.cpp:749-779)', () {
    test('mode outside all/one/off/shuffle becomes all', () async {
      await writeSession(sessionJson(player: playerJson(mode: 'bogus')));
      expect((await load()).player!.mode, 'all');
    });

    test('position outside 0..1e12 stops the WHOLE player restore', () async {
      await writeSession(sessionJson(player: playerJson(position: 1.0e12 + 1)));
      expect((await load()).player, isNull);
    });

    test('queue identity deduplicates keeping the first occurrence', () async {
      await writeSession(sessionJson(player: playerJson(queue: <Object?>[
        <String, Object?>{'id': 'a', 'kind': 'song', 'provider': 'netease'},
        <String, Object?>{'id': 'a', 'kind': 'song', 'provider': 'netease'},
        <String, Object?>{'id': 'b', 'kind': 'song', 'provider': 'netease'},
      ])));
      final PlayerState p = (await load()).player!;
      expect(p.queue.length, 2);
      expect(p.queue.first['id'], 'a');
    });

    test('deferred ids are retained through the GUI-exclusive restore', () async {
      await writeSession(sessionJson(
        player: playerJson(queue: <Object?>[
          <String, Object?>{'id': 'a', 'kind': 'song', 'provider': 'netease'},
          <String, Object?>{'id': 'b', 'kind': 'song', 'provider': 'netease', 'deferred': true},
          <String, Object?>{'id': 'a', 'kind': 'song', 'provider': 'netease'},
          <String, Object?>{'id': 'c', 'kind': 'song', 'provider': 'qq'},
        ]),
      ));
      final SessionRestoreResult r = await load();
      // PlaybackQueue.cpp:404-405: every usable id in archive order, before the deferred
      // test, duplicates included; the complete queue keeps only "a" and "c".
      expect(r.player!.deferredIds, <String>['a', 'b', 'a', 'c']);
      expect(r.player!.queue.map((Map<String, Object?> t) => t['id']).toList(), <Object?>['a', 'c']);
      // The id list is restore output, never archive state: a save must not add it.
      expect(await store.save(r.library!, r.player!, r.view!), isTrue);
      expect((await File(storage.sessionPath).readAsString()).contains('deferred'), isFalse);
    });

    test('the background-connection branch restores no player while the service load keeps the ids', () async {
      await writeSession(sessionJson(
        player: playerJson(queue: <Object?>[
          <String, Object?>{'id': 'a', 'kind': 'song', 'provider': 'netease'},
          <String, Object?>{'id': 'b', 'kind': 'song', 'provider': 'netease', 'deferred': true},
        ]),
      ));
      // MusicSession.cpp:263-265: the GUI skips the player entirely while the background
      // playback connection owns playback state, so nothing is lost here - nothing is
      // read. The process that DOES restore is the service (Host.h:85-87: its
      // playbackConnection() is null, so hydrate is true) and its id list survives.
      expect((await load(playbackConnection: true)).player, isNull);
      final PlayerState service = (await PlaybackStore(storage: storage)
          .load(currentProvider: identity.provider))!;
      expect(service.deferredIds, <String>['a', 'b']);
      expect(service.queue.single['id'], 'a');
    });
  });

  group('T26-S02 save, atomicity and the 64 MiB cap (Qt/src/MusicSession.cpp:269-284)', () {
    test('over the cap the previous archive survives byte for byte', () async {
      await writeSession(sessionJson());
      final String before = await File(storage.sessionPath).readAsString();
      final SessionRestoreResult r = await load();
      final Map<String, Object?> library = Map<String, Object?>.from(r.library!);
      library['keyword'] = 'x' * (64 * 1024 * 1024 + 1);
      final bool ok = await store.save(library, r.player!, r.view!);
      expect(ok, isFalse);
      expect(await File(storage.sessionPath).readAsString(), before);
    });

    test('a normal save writes exactly version/library/player/view with 16 view keys', () async {
      await writeSession(sessionJson());
      final SessionRestoreResult r = await load();
      expect(await store.save(r.library!, r.player!, r.view!), isTrue);
      final Map<String, Object?> written =
          jsonDecode(await File(storage.sessionPath).readAsString())! as Map<String, Object?>;
      expect(written.keys.toList(), <String>['version', 'library', 'player', 'view']);
      expect(written['version'], 1);
      final Map<String, Object?> view = written['view']! as Map<String, Object?>;
      expect(view.length, 16);
      expect(view.containsKey('notARealField'), isFalse);
    });

    test('offline writes nothing at all', () async {
      await writeSession(sessionJson());
      final String before = await File(storage.sessionPath).readAsString();
      final SessionRestoreResult r = await load();
      final AppStorage offlineStorage = AppStorage(
        paths: storage.paths,
        files: storage.files,
        offline: true,
      );
      final SessionStore offlineStore = SessionStore(storage: offlineStorage);
      expect(await offlineStore.save(r.library!, r.player!, r.view!), isFalse);
      expect(await File(storage.sessionPath).readAsString(), before);
    });
  });
}
