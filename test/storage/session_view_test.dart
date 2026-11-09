// T26-S02 session.json view/store contract tests.
//
// UNEXECUTED in this atom: no dart/flutter test, analyze or build may run here.
// Every expectation below cites the Qt rule it expresses (baseline 8ed3067).
//
// Real file-system work happens only under Directory.systemTemp. The gate tests
// use an in-memory FileSystemPort so that "the file is never deleted" can be
// observed directly.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import '../../lib/data/storage/app_storage.dart';
import '../../lib/data/storage/playback_store.dart';
import '../../lib/data/storage/session_store.dart';

const SessionIdentity _identity =
    SessionIdentity(provider: 'kugou', edition: 'standard', uid: '');

AppStoragePaths _paths() {
  final base = joinPath(Directory.systemTemp.path, 'rhine-t26-s02');
  return AppStoragePaths(
    dataDirectory: joinPath(base, 'data'),
    cacheDirectory: joinPath(base, 'cache'),
    temporaryDirectory: joinPath(Directory.systemTemp.path, 'rhine-t26-s02-tmp'),
    executableDirectory: joinPath(base, 'bin'),
  );
}

class _MemoryFiles implements FileSystemPort {
  final Map<String, List<int>> files = <String, List<int>>{};
  final List<String> deleted = <String>[];
  final List<String> removedTrees = <String>[];
  final List<String> written = <String>[];
  final List<String> createdDirectories = <String>[];

  /// exists() true but sizeOrNegative() -1: the unreadable case.
  bool failSize = false;

  /// sizeOrNegative() fine but readAll() null: the unreadable case.
  bool failRead = false;

  @override
  Future<bool> exists(String path) async => files.containsKey(path);

  @override
  Future<int> sizeOrNegative(String path) async =>
      failSize ? -1 : (files[path]?.length ?? -1);

  @override
  Future<List<int>?> readAll(String path) async =>
      failRead ? null : files[path];

  @override
  Future<List<String>> list(String directory) async => <String>[];

  @override
  Future<void> createDirectory(String directory) async {
    createdDirectories.add(directory);
  }

  @override
  Future<void> writeAtomic(String path, List<int> bytes) async {
    written.add(path);
    files[path] = bytes;
  }

  @override
  Future<void> removeFile(String path) async {
    deleted.add(path);
    files.remove(path);
  }

  @override
  Future<void> removeTree(String path) async {
    removedTrees.add(path);
    files.clear();
  }
}

class _CapturingStorage extends AppStorage {
  _CapturingStorage({required super.paths, super.files});

  bool? capturedOffline;
  Object? capturedJson;
  int? capturedLimit;
  String? capturedPath;

  @override
  Future<bool> writeJsonAtomic(
    String path,
    Object? json, {
    int limitBytes = kSessionLimitBytes,
  }) async {
    capturedPath = path;
    capturedJson = json;
    capturedLimit = limitBytes;
    return true;
  }
}

List<Object?> _lanes() => <Object?>[
      for (var lane = 0; lane < 5; lane++)
        <String, Object?>{
          'items': <Object?>[],
          'total': 0,
          'offset': 0,
          'more': false,
          'row': 0,
        },
    ];

Map<String, Object?> _library({
  String provider = 'kugou',
  String edition = 'standard',
  String uid = '',
  List<Object?>? sources,
  List<Object?>? directories,
  Object? current,
  Object? selectedPhysical = -1,
  Object? selectedLane = 0,
}) =>
    <String, Object?>{
      'provider': provider,
      'edition': edition,
      'uid': uid,
      'sources': sources ?? _lanes(),
      'directories': directories ?? <Object?>[],
      'current': current ?? <String, Object?>{},
      'selectedPhysical': selectedPhysical,
      'selectedLane': selectedLane,
    };

Map<String, Object?> _session({
  Object? version = 1,
  Map<String, Object?>? library,
  Object? player,
  Object? view,
}) =>
    <String, Object?>{
      'version': version,
      'library': library ?? _library(),
      'player': player ??
          <String, Object?>{
            'current': <String, Object?>{},
            'queue': <Object?>[],
            'index': 0,
            'mode': 'off',
            'position': 0,
            'requested': false,
            'preview': false,
          },
      'view': view ?? <String, Object?>{},
    };

_MemoryFiles _filesWith(Map<String, Object?> session) {
  final files = _MemoryFiles();
  files.files[joinPath(_paths().dataDirectory, 'session.json')] =
      utf8.encode(jsonEncode(session));
  return files;
}

SessionStore _store(
  FileSystemPort files, {
  int Function()? settingsScrollMaximum,
  List<List<int>>? physicalSlots,
  bool offline = false,
}) =>
    SessionStore(
      storage: AppStorage(paths: _paths(), files: files, offline: offline),
      settingsScrollMaximum: settingsScrollMaximum,
      physicalSlots: physicalSlots,
    );

/// Asserts the failure shape shared by every gate: nothing restored, nothing
/// deleted (T07 2.1: on failure the file is kept).
void _expectKeptFailure(SessionRestoreResult result, String reason,
    _MemoryFiles files) {
  expect(result.loaded, isFalse);
  expect(result.failureReason, reason);
  expect(result.view, isNull);
  expect(result.player, isNull);
  expect(result.library, isNull);
  expect(files.deleted, isEmpty);
  expect(files.removedTrees, isEmpty);
  expect(files.files.containsKey(joinPath(_paths().dataDirectory, 'session.json')),
      isTrue);
}

void main() {
  group('view contract', () {
    test('toJson emits exactly the 16 frozen keys in order', () {
      // MusicSession.cpp:219-234.
      expect(ViewState.viewKeys, hasLength(16));
      final view = ViewState.restore(
        <String, Object?>{},
        currentNonEmpty: false,
        settingsScrollMaximum: 764,
      );
      expect(view.toJson().keys.toList(), orderedEquals(ViewState.viewKeys));
      expect(view.toJson().keys.toList().length, 16);
    });

    test('unknown view fields are dropped and never re-emitted', () {
      // T07 2.3: unknown view fields are ignored on read and never written back.
      final view = ViewState.restore(
        <String, Object?>{'bogus': 1, 'another': 'x', 'selected': 3},
        currentNonEmpty: false,
        settingsScrollMaximum: 764,
      );
      final json = view.toJson();
      expect(json.containsKey('bogus'), isFalse);
      expect(json.containsKey('another'), isFalse);
      expect(json.keys.toList(), orderedEquals(ViewState.viewKeys));
    });

    test('illegal modal restores to no modal and is written back empty', () {
      // MusicSession.cpp:242-245 whitelist; written value is '' when none is open.
      for (final bad in <Object?>['bogus', '', 7, null, 'SETTINGS']) {
        final view = ViewState.restore(
          <String, Object?>{'modal': bad},
          currentNonEmpty: false,
          settingsScrollMaximum: 764,
        );
        expect(view.modal, '', reason: 'modal input: ' + bad.toString());
        expect(view.toJson()['modal'], '');
      }
      for (final good in ViewState.modals) {
        final view = ViewState.restore(
          <String, Object?>{'modal': good},
          currentNonEmpty: false,
          settingsScrollMaximum: 764,
        );
        expect(view.modal, good);
      }
    });

    test('mode is detail only when library.current is non-empty', () {
      // MusicSession.cpp:262.
      expect(
        ViewState.restore(<String, Object?>{'mode': 'detail'},
                currentNonEmpty: false, settingsScrollMaximum: 764)
            .mode,
        'archive',
      );
      expect(
        ViewState.restore(<String, Object?>{'mode': 'detail'},
                currentNonEmpty: true, settingsScrollMaximum: 764)
            .mode,
        'detail',
      );
      expect(
        ViewState.restore(<String, Object?>{'mode': 'bogus'},
                currentNonEmpty: true, settingsScrollMaximum: 764)
            .mode,
        'archive',
      );
      expect(
        ViewState.restore(<String, Object?>{},
                currentNonEmpty: true, settingsScrollMaximum: 764)
            .mode,
        'archive',
      );
    });

    test('tab whitelist and defaults', () {
      // MusicSession.cpp:248-249.
      expect(
        ViewState.restore(<String, Object?>{'tab': 'notes'},
                currentNonEmpty: false, settingsScrollMaximum: 764)
            .tab,
        'notes',
      );
      for (final bad in <Object?>['bogus', '', 4, null]) {
        expect(
          ViewState.restore(<String, Object?>{'tab': bad},
                  currentNonEmpty: false, settingsScrollMaximum: 764)
              .tab,
          'overview',
        );
      }
    });

    test('selected clamps to 0..39 and is the global physical slot', () {
      // MusicSession.cpp:260.
      expect(
        ViewState.restore(<String, Object?>{'selected': 40},
                currentNonEmpty: false, settingsScrollMaximum: 764)
            .selected,
        39,
      );
      expect(
        ViewState.restore(<String, Object?>{'selected': 40},
                currentNonEmpty: false, settingsScrollMaximum: 764)
            .toJson()['selected'],
        39,
      );
      expect(
        ViewState.restore(<String, Object?>{'selected': -1},
                currentNonEmpty: false, settingsScrollMaximum: 764)
            .selected,
        0,
      );
      for (final missing in <Object?>[null, 'x', true, <String, Object?>{}]) {
        expect(
          ViewState.restore(<String, Object?>{'selected': missing},
                  currentNonEmpty: false, settingsScrollMaximum: 764)
              .selected,
          0,
        );
      }
    });

    test('musicCollection clamps to 1..4 with default 1', () {
      // MusicSession.cpp:257.
      expect(
        ViewState.restore(<String, Object?>{'musicCollection': 0},
                currentNonEmpty: false, settingsScrollMaximum: 764)
            .musicCollection,
        1,
      );
      expect(
        ViewState.restore(<String, Object?>{'musicCollection': 9},
                currentNonEmpty: false, settingsScrollMaximum: 764)
            .musicCollection,
        4,
      );
      for (final missing in <Object?>[null, 'x', true]) {
        expect(
          ViewState.restore(<String, Object?>{'musicCollection': missing},
                  currentNonEmpty: false, settingsScrollMaximum: 764)
              .musicCollection,
          1,
        );
      }
    });

    test('settingsScroll clamps to the injected runtime maximum', () {
      // MusicSession.cpp:247 with the injected layout function (NativeHud.h:132-135).
      expect(
        ViewState.restore(<String, Object?>{'settingsScroll': 5000},
                currentNonEmpty: false, settingsScrollMaximum: 764)
            .settingsScroll,
        764.0,
      );
      expect(
        ViewState.restore(<String, Object?>{'settingsScroll': 30.5},
                currentNonEmpty: false, settingsScrollMaximum: 764)
            .settingsScroll,
        30.5,
      );
      expect(
        ViewState.restore(<String, Object?>{'settingsScroll': -2},
                currentNonEmpty: false, settingsScrollMaximum: 764)
            .settingsScroll,
        0.0,
      );
      for (final missing in <Object?>[null, 'x', true]) {
        expect(
          ViewState.restore(<String, Object?>{'settingsScroll': missing},
                  currentNonEmpty: false, settingsScrollMaximum: 764)
              .settingsScroll,
          0.0,
        );
      }
      // A saved value may exceed the CURRENT maximum, which is injected.
      expect(
        ViewState.restore(<String, Object?>{'settingsScroll': 100},
                currentNonEmpty: false, settingsScrollMaximum: 10)
            .settingsScroll,
        10.0,
      );
    });

    test('offsets are non-negative and non-bools are false', () {
      // MusicSession.cpp:246, :258-259.
      final view = ViewState.restore(
        <String, Object?>{
          'queueOffset': -5,
          'listOffset': -1,
          'trackOffset': -9,
          'bodyOffset': -3,
          'trackListMode': 'yes',
          'lyricsMode': 1,
        },
        currentNonEmpty: false,
        settingsScrollMaximum: 764,
      );
      expect(view.queueOffset, 0);
      expect(view.listOffset, 0);
      expect(view.trackOffset, 0);
      expect(view.bodyOffset, 0);
      expect(view.trackListMode, isFalse);
      expect(view.lyricsMode, isFalse);
      final saved = ViewState.restore(
        <String, Object?>{
          'queueOffset': 12,
          'listOffset': 3,
          'trackOffset': 4,
          'bodyOffset': 5,
          'trackListMode': true,
          'lyricsMode': true,
        },
        currentNonEmpty: false,
        settingsScrollMaximum: 764,
      );
      expect(saved.queueOffset, 12);
      expect(saved.listOffset, 3);
      expect(saved.trackOffset, 4);
      expect(saved.bodyOffset, 5);
      expect(saved.trackListMode, isTrue);
      expect(saved.lyricsMode, isTrue);
    });

    test('strings: non-strings take defaults, empty groupBy is preserved', () {
      // MusicSession.cpp:250-256.
      final view = ViewState.restore(
        <String, Object?>{
          'query': 5,
          'groupBy': '',
          'activeGroup': 7,
          'artistTab': <Object?>[],
        },
        currentNonEmpty: false,
        settingsScrollMaximum: 764,
      );
      expect(view.query, '');
      expect(view.groupBy, '');
      expect(view.activeGroup, '');
      expect(view.artistTab, 'songs');
      final defaults = ViewState.restore(
        <String, Object?>{},
        currentNonEmpty: false,
        settingsScrollMaximum: 764,
      );
      expect(defaults.query, '');
      expect(defaults.groupBy, 'none');
      expect(defaults.activeGroup, '');
      expect(defaults.artistTab, 'songs');
    });

    test('settingsScrollMaximum default mirrors the Qt layout constants', () {
      // NativeHud.h:115-135 + HudScroll.h:13-15 => 764.
      expect(SessionStore.defaultSettingsScrollMaximum(), 764);
      expect(SessionStore.settingsViewportTop, 176);
      expect(SessionStore.settingsViewportBottom, 836);
      expect(SessionStore.defaultSettingsContentBottom, 1600);
    });
  });

  group('read gate', () {
    test('64 MiB session limit', () {
      // NativeApplication.cpp:66 and MusicSession.cpp:276.
      expect(SessionStore.sessionLimitBytes, 64 * 1024 * 1024);
      expect(SessionStore.sessionLimitBytes, 67108864);
      expect(kSessionFailureReasons, hasLength(11));
    });

    test('missing file fails with missing and deletes nothing', () async {
      final files = _MemoryFiles();
      final result = await _store(files).loadForRestore(_identity,
          playbackConnection: false);
      _expectKeptFailure(result, 'missing', files);
    });

    test('oversize file fails with oversize and deletes nothing', () async {
      final files = _filesWith(_session());
      final path = joinPath(_paths().dataDirectory, 'session.json');
      files.files[path] = Uint8List(SessionStore.sessionLimitBytes + 1);
      final result = await _store(files).loadForRestore(_identity,
          playbackConnection: false);
      _expectKeptFailure(result, 'oversize', files);
      expect(files.files[path]!.length, SessionStore.sessionLimitBytes + 1);
    });

    test('unreadable when the size cannot be read', () async {
      final files = _filesWith(_session())..failSize = true;
      final result = await _store(files).loadForRestore(_identity,
          playbackConnection: false);
      _expectKeptFailure(result, 'unreadable', files);
    });

    test('unreadable when the bytes cannot be read', () async {
      final files = _filesWith(_session())..failRead = true;
      final result = await _store(files).loadForRestore(_identity,
          playbackConnection: false);
      _expectKeptFailure(result, 'unreadable', files);
    });

    test('invalid-json on malformed bytes', () async {
      final files = _MemoryFiles();
      files.files[joinPath(_paths().dataDirectory, 'session.json')] =
          utf8.encode('{not json');
      final result = await _store(files).loadForRestore(_identity,
          playbackConnection: false);
      _expectKeptFailure(result, 'invalid-json', files);
    });

    test('invalid-json when the top level is not an object', () async {
      final files = _MemoryFiles();
      files.files[joinPath(_paths().dataDirectory, 'session.json')] =
          utf8.encode('[1,2,3]');
      final result = await _store(files).loadForRestore(_identity,
          playbackConnection: false);
      _expectKeptFailure(result, 'invalid-json', files);
    });

    test('version other than 1 fails with version', () async {
      // MusicSession.cpp:238.
      for (final bad in <Object?>[2, 0, '1', null, 1.5]) {
        final files = _filesWith(_session(version: bad));
        final result = await _store(files).loadForRestore(_identity,
            playbackConnection: false);
        _expectKeptFailure(result, 'version', files);
      }
      final ok = _filesWith(_session(version: 1.0));
      final result = await _store(ok).loadForRestore(_identity,
          playbackConnection: false);
      expect(result.loaded, isTrue);
    });
  });

  group('library identity gate', () {
    test('provider mismatch', () async {
      final files = _filesWith(_session(library: _library(provider: 'netease')));
      _expectKeptFailure(
          await _store(files).loadForRestore(_identity, playbackConnection: false),
          'provider-mismatch',
          files);
    });

    test('provider must be a string', () async {
      final library = _library();
      library['provider'] = 3;
      final files = _filesWith(_session(library: library));
      _expectKeptFailure(
          await _store(files).loadForRestore(_identity, playbackConnection: false),
          'provider-mismatch',
          files);
    });

    test('edition mismatch', () async {
      final files = _filesWith(_session(library: _library(edition: 'lite')));
      _expectKeptFailure(
          await _store(files).loadForRestore(_identity, playbackConnection: false),
          'edition-mismatch',
          files);
    });

    test('uid mismatch', () async {
      final files = _filesWith(_session(library: _library(uid: 'u1')));
      _expectKeptFailure(
          await _store(files).loadForRestore(_identity, playbackConnection: false),
          'uid-mismatch',
          files);
      // A non-string uid reads as '' through QString::toString() and matches a
      // logged-out identity (MusicSession.cpp:89-91).
      final library = _library();
      library['uid'] = 123;
      final files2 = _filesWith(_session(library: library));
      final result = await _store(files2)
          .loadForRestore(_identity, playbackConnection: false);
      expect(result.loaded, isTrue);
    });

    test('logged-in identity requires the saved uid', () async {
      const signedIn = SessionIdentity(provider: 'qq', edition: 'lite', uid: '9');
      final ok = _filesWith(_session(
          library: _library(provider: 'qq', edition: 'lite', uid: '9')));
      expect(
        (await _store(ok).loadForRestore(signedIn, playbackConnection: false))
            .loaded,
        isTrue,
      );
      final bad = _filesWith(_session(
          library: _library(provider: 'qq', edition: 'lite', uid: '')));
      _expectKeptFailure(
          await _store(bad).loadForRestore(signedIn, playbackConnection: false),
          'uid-mismatch',
          bad);
    });

    test('sources must be exactly 5 lanes', () async {
      // MusicSession.cpp:92-98.
      final four = _filesWith(
          _session(library: _library(sources: _lanes().sublist(0, 4))));
      _expectKeptFailure(
          await _store(four).loadForRestore(_identity, playbackConnection: false),
          'sources-length',
          four);
      final six = _filesWith(_session(
          library: _library(sources: <Object?>[..._lanes(), <String, Object?>{}])));
      _expectKeptFailure(
          await _store(six).loadForRestore(_identity, playbackConnection: false),
          'sources-length',
          six);
      final none = _filesWith(_session(library: _library(sources: <Object?>[])));
      _expectKeptFailure(
          await _store(none).loadForRestore(_identity, playbackConnection: false),
          'sources-length',
          none);
    });

    test('directories must not exceed 64 entries', () async {
      // MusicSession.cpp:99-102.
      final tooMany = _filesWith(
          _session(library: _library(directories: List<Object?>.filled(65, <String, Object?>{}))));
      _expectKeptFailure(
          await _store(tooMany)
              .loadForRestore(_identity, playbackConnection: false),
          'directories-too-many',
          tooMany);
      final exactly = _filesWith(
          _session(library: _library(directories: List<Object?>.filled(64, <String, Object?>{}))));
      expect(
        (await _store(exactly)
                .loadForRestore(_identity, playbackConnection: false))
            .loaded,
        isTrue,
      );
    });

    test('selectedPhysical range and lane', () async {
      // MusicSession.cpp:92-98.
      for (final bad in <Object?>[40, -2, null]) {
        final files =
            _filesWith(_session(library: _library(selectedPhysical: bad)));
        _expectKeptFailure(
            await _store(files)
                .loadForRestore(_identity, playbackConnection: false),
            'selected-physical',
            files);
      }
      for (final badLane in <Object?>[5, -1, null]) {
        final files =
            _filesWith(_session(library: _library(selectedLane: badLane)));
        _expectKeptFailure(
            await _store(files)
                .loadForRestore(_identity, playbackConnection: false),
            'selected-physical',
            files);
      }
      final ok = _filesWith(_session(library: _library(selectedPhysical: 39)));
      expect(
        (await _store(ok).loadForRestore(_identity, playbackConnection: false))
            .loaded,
        isTrue,
      );
    });

    test('selectedPhysical must belong to physicalSlots[selectedLane]', () async {
      // MusicLibrary.cpp:50-58 + MusicSession.cpp:92-98.
      final slots = <List<int>>[
        <int>[0, 2],
        <int>[1],
        <int>[],
        <int>[],
        <int>[],
      ];
      final miss = _filesWith(
          _session(library: _library(selectedPhysical: 3, selectedLane: 0)));
      _expectKeptFailure(
          await _store(miss, physicalSlots: slots)
              .loadForRestore(_identity, playbackConnection: false),
          'selected-physical',
          miss);
      final hit = _filesWith(
          _session(library: _library(selectedPhysical: 2, selectedLane: 0)));
      expect(
        (await _store(hit, physicalSlots: slots)
                .loadForRestore(_identity, playbackConnection: false))
            .loaded,
        isTrue,
      );
      // physical -1 means "none selected" and skips the membership check.
      final none = _filesWith(
          _session(library: _library(selectedPhysical: -1, selectedLane: 4)));
      expect(
        (await _store(none, physicalSlots: slots)
                .loadForRestore(_identity, playbackConnection: false))
            .loaded,
        isTrue,
      );
    });

    test('derivePhysicalSlots mirrors MusicLibrary.cpp:50-58', () {
      final slots = SessionStore.derivePhysicalSlots(<String, Object?>{
        'columns': <Object?>['a', 'b'],
        'records': <Object?>[
          <String, Object?>{'category': 'a'},
          <String, Object?>{'category': 'b'},
          <String, Object?>{'category': 'a'},
        ],
      });
      expect(slots, hasLength(5));
      expect(slots[0], orderedEquals(<int>[0, 2]));
      expect(slots[1], orderedEquals(<int>[1]));
      expect(slots[2], isEmpty);
      expect(slots[3], isEmpty);
      expect(slots[4], isEmpty);
    });

    test('a failed gate keeps view and player null', () async {
      final files = _filesWith(_session(
        library: _library(provider: 'netease'),
        view: <String, Object?>{'selected': 7, 'modal': 'settings'},
      ));
      final result = await _store(files)
          .loadForRestore(_identity, playbackConnection: false);
      _expectKeptFailure(result, 'provider-mismatch', files);
      expect(result.library, isNull);
      expect(result.view, isNull);
      expect(result.player, isNull);
    });
  });

  group('library state restoration', () {
    test('sources clamps: total, offset, row, more', () async {
      // MusicSession.cpp:106-113.
      final sources = <Object?>[
        <String, Object?>{
          'items': <Object?>['a', 'b', 'c'],
          'total': 1,
          'offset': 9,
          'more': 'yes',
          'row': 9,
        },
        <String, Object?>{'items': <Object?>[], 'total': -5, 'offset': -2, 'row': -1},
        <String, Object?>{},
        <String, Object?>{},
        <String, Object?>{},
      ];
      final files = _filesWith(_session(library: _library(sources: sources)));
      final result = await _store(files)
          .loadForRestore(_identity, playbackConnection: false);
      expect(result.loaded, isTrue);
      final restored = (result.library!['sources'] as List<Object?>)
          .cast<Map<String, Object?>>();
      expect(restored, hasLength(5));
      expect(restored[0]['total'], 3);
      expect(restored[0]['offset'], 2);
      expect(restored[0]['more'], isFalse);
      expect(restored[0]['row'], 7);
      expect((restored[0]['items'] as List<Object?>), orderedEquals(<Object?>['a', 'b', 'c']));
      expect(restored[1]['total'], 0);
      expect(restored[1]['offset'], 0);
      expect(restored[1]['row'], 0);
      expect(restored[2]['more'], isFalse);
    });

    test('directory clamps and the recomputed page', () async {
      // MusicSession.cpp:114-137, page = index / 40 * 40 at :130.
      final map = <String, Object?>{
        'item': <String, Object?>{'id': 'x'},
        'songs': List<Object?>.filled(100, <String, Object?>{}),
        'sortField': 'bogus',
        'ids': <Object?>['i1', 'i2'],
        'albums': <Object?>[],
        'cursor': 99,
        'index': 100,
        'page': 999,
        'anchor': 99,
        'parentPhysical': 99,
        'parentLane': 9,
        'parentItem': <String, Object?>{},
        'albumCursor': -4,
        'albumsMore': 1,
      };
      final files = _filesWith(
          _session(library: _library(directories: <Object?>[map])));
      final result = await _store(files)
          .loadForRestore(_identity, playbackConnection: false);
      expect(result.loaded, isTrue);
      final entry = (result.library!['directories'] as List<Object?>).first
          as Map<String, Object?>;
      expect(entry['cursor'], 2);
      expect(entry['index'], 99, reason: 'index clamps to songs.length - 1');
      expect(entry['page'], 80, reason: 'page is index ~/ 40 * 40, never read');
      expect(entry['anchor'], 39);
      expect(entry['parentPhysical'], 39);
      expect(entry['parentLane'], 4);
      expect(entry['albumCursor'], 0);
      expect(entry['albumsMore'], isFalse);
      expect(entry['sortField'], 'none');
      expect(entry['item'], <String, Object?>{'id': 'x'});
    });

    test('directory defaults and the sortField whitelist', () async {
      final files = _filesWith(_session(
        library: _library(directories: <Object?>[
          <String, Object?>{
            'songs': List<Object?>.filled(100, <String, Object?>{}),
            'sortField': 'title',
            'index': 85,
            'anchor': -4,
            'parentLane': -1,
            'cursor': -7,
          },
        ]),
      ));
      final result = await _store(files)
          .loadForRestore(_identity, playbackConnection: false);
      final entry = (result.library!['directories'] as List<Object?>).first
          as Map<String, Object?>;
      expect(entry['sortField'], 'title');
      expect(entry['page'], 80, reason: '85 ~/ 40 * 40');
      expect(entry['anchor'], 0);
      expect(entry['parentLane'], 0);
      expect(entry['cursor'], 0);
      expect(entry['ids'], isEmpty);
      expect(entry['albums'], isEmpty);
      expect(entry['index'], 0);
      for (final good in <String>['none', 'title', 'album', 'artist']) {
        final accepted = await _store(_filesWith(_session(
          library: _library(directories: <Object?>[
            <String, Object?>{'sortField': good},
          ]),
        ))).loadForRestore(_identity, playbackConnection: false);
        expect(accepted.loaded, isTrue);
        expect(
          ((accepted.library!['directories'] as List<Object?>).first
              as Map<String, Object?>)['sortField'],
          good,
        );
      }
    });

    test('scalar library fields clamp and default', () async {
      final library = _library();
      library.addAll(<String, Object?>{
        'keyword': 5,
        'searchKind': 5,
        'status': 5,
        'searchCursor': -1,
        'playlistCursor': -2,
        'albumCursor': -3,
        'likedCursor': -4,
        'trackCursor': -5,
        'likedIDs': 'nope',
        'groupName': 5,
        'groupIndices': <Object?>[-1, 2, -3],
        'groupLane': 9,
        'tracks': 'nope',
        'trackIDs': <Object?>['t1'],
        'albumLoaded': 1,
        'playContext': <Object?>[],
        'directoryInfo': 0,
        'wantsSongDetails': 'yes',
        'privateSelection': 1,
        'searchLoading': 1,
        'directoryLoading': <Object?>[],
        'detailLoading': true,
        'discover': <String, Object?>{'offset': -6, 'more': 1, 'tab': 5, 'items': 5},
      });
      final files = _filesWith(_session(library: library));
      final result = await _store(files)
          .loadForRestore(_identity, playbackConnection: false);
      expect(result.loaded, isTrue);
      final restored = result.library!;
      expect(restored['keyword'], '');
      expect(restored['searchKind'], 'song');
      expect(restored['status'], '');
      expect(restored['searchCursor'], 0);
      expect(restored['playlistCursor'], 0);
      expect(restored['albumCursor'], 0);
      expect(restored['likedCursor'], 0);
      expect(restored['trackCursor'], 0);
      expect(restored['likedIDs'], isNull);
      expect(restored['groupName'], '');
      expect(restored['groupIndices'], orderedEquals(<Object?>[0, 2, 0]));
      expect(restored['groupLane'], 4);
      expect(restored['tracks'], isEmpty);
      expect(restored['trackIDs'], orderedEquals(<Object?>['t1']));
      expect(restored['albumLoaded'], isFalse);
      expect(restored['playContext'], isEmpty);
      expect(restored['directoryInfo'], isFalse);
      expect(restored['wantsSongDetails'], isFalse);
      expect(restored['privateSelection'], isTrue);
      // Qt/src/MusicSession.cpp:164 forces these false on restore; the saved
      // booleans are only re-issue triggers (:177-186), surfaced separately.
      expect(restored['searchLoading'], isFalse);
      expect(restored['directoryLoading'], isFalse);
      expect(restored['detailLoading'], isFalse);
      expect(result.triggers.search, isFalse); // '1' is not a bool, keyword is ''
      expect(result.triggers.directory, isFalse); // no directories in the fixture
      expect(result.triggers.detail, isFalse); // current is empty
      final discover = restored['discover'] as Map<String, Object?>;
      expect(discover['tab'], 'playlists');
      expect(discover['items'], isEmpty);
      expect(discover['offset'], 0);
      expect(discover['more'], isFalse);
      expect(discover['category'], '全部');
      expect(discover['newSongArea'], '5');
      expect(restored['groupLane'], 4);
    });

    test('in-flight requests become triggers and are never restored as state', () async {
      // Qt/src/MusicSession.cpp:177-186: the saved booleans only decide whether to
      // re-issue the request; :164 clears detailLoading/directoryLoading first.
      final library = _library(
        current: <String, Object?>{'kind': 'song', 'id': 't1'},
        directories: <Object?>[
          <String, Object?>{
            'item': <String, Object?>{},
            'songs': <Object?>[],
            'ids': <Object?>[],
            'albums': <Object?>[],
            'sortField': 'none',
            'cursor': 0,
            'index': 0,
            'anchor': 0,
            'page': 0,
            'parentPhysical': 0,
            'parentLane': 0,
            'parentItem': <String, Object?>{},
            'albumCursor': 0,
            'albumsMore': false,
          },
        ],
      );
      library.addAll(<String, Object?>{
        'keyword': 'blue',
        'searchLoading': true,
        'directoryLoading': true,
        'detailLoading': true,
      });
      final files = _filesWith(_session(library: library));
      final result =
          await _store(files).loadForRestore(_identity, playbackConnection: false);
      expect(result.loaded, isTrue);
      final restored = result.library!;
      expect(restored['searchLoading'], isFalse);
      expect(restored['directoryLoading'], isFalse);
      expect(restored['detailLoading'], isFalse);
      expect(result.triggers.search, isTrue);
      // The directory branch wins the else-if chain, so detail must not fire too.
      expect(result.triggers.directory, isTrue);
      expect(result.triggers.detail, isFalse);

      // A clean session restores no triggers at all.
      final clean = await _store(_filesWith(_session()))
          .loadForRestore(_identity, playbackConnection: false);
      expect(clean.triggers.search, isFalse);
      expect(clean.triggers.directory, isFalse);
      expect(clean.triggers.detail, isFalse);
    });

    test('groupLane -1 is preserved and likedIDs arrays survive', () async {
      final library = _library();
      library['groupLane'] = -1;
      library['likedIDs'] = <Object?>['a', 'b'];
      library['discover'] = <String, Object?>{
        'tab': 'albums',
        'items': <Object?>['i'],
        'offset': 3,
        'more': true,
        'category': 'x',
        'newSongArea': '9',
      };
      final result = await _store(_filesWith(_session(library: library)))
          .loadForRestore(_identity, playbackConnection: false);
      final restored = result.library!;
      expect(restored['groupLane'], -1);
      expect(restored['likedIDs'], orderedEquals(<Object?>['a', 'b']));
      final discover = restored['discover'] as Map<String, Object?>;
      expect(discover['tab'], 'albums');
      expect(discover['items'], orderedEquals(<Object?>['i']));
      expect(discover['offset'], 3);
      expect(discover['more'], isTrue);
      expect(discover['category'], 'x');
      expect(discover['newSongArea'], '9');
    });

    test('current is restored verbatim, including a non-empty one', () async {
      final library = _library(current: <String, Object?>{'id': 'siren-1'});
      final result = await _store(_filesWith(_session(
        library: library,
        view: <String, Object?>{'mode': 'detail'},
      ))).loadForRestore(_identity, playbackConnection: false);
      expect(result.loaded, isTrue);
      expect(result.library!['current'], <String, Object?>{'id': 'siren-1'});
      expect(result.view!.mode, 'detail');
    });
  });

  group('player and playback connection', () {
    test('player is not restored when the playback connection exists', () async {
      // MusicSession.cpp:263-265.
      final files = _filesWith(_session());
      final result = await _store(files)
          .loadForRestore(_identity, playbackConnection: true);
      expect(result.loaded, isTrue);
      expect(result.player, isNull);
    });

    test('player is restored when there is no playback connection', () async {
      // MusicSession.cpp:263-265 delegates to MusicPlayer::restoreSessionState,
      // ported by T26-S03 as normalizePlayer.
      final result = await _store(_filesWith(_session()))
          .loadForRestore(_identity, playbackConnection: false);
      expect(result.loaded, isTrue);
      expect(result.player, isNotNull);
    });

    test('a failed library gate leaves the player null too', () async {
      final files = _filesWith(_session(library: _library(provider: 'netease')));
      final result = await _store(files)
          .loadForRestore(_identity, playbackConnection: false);
      expect(result.player, isNull);
      _expectKeptFailure(result, 'provider-mismatch', files);
    });
  });

  group('save', () {
    test('offline writes nothing and returns false', () async {
      // MusicSession.cpp:269-272.
      final files = _MemoryFiles();
      final storage = _CapturingStorage(paths: _paths(), files: files)
        ..offline = true;
      final store = SessionStore(storage: storage);
      final saved = await store.save(
        _library(),
        _player(),
        ViewState.restore(<String, Object?>{},
            currentNonEmpty: false, settingsScrollMaximum: 764),
      );
      expect(saved, isFalse);
      expect(storage.capturedJson, isNull);
      expect(files.written, isEmpty);
      expect(files.files, isEmpty);
    });

    test('writes exactly {version, library, player, view} at the 64 MiB cap',
        () async {
      // MusicSession.cpp:215-235 + :276 + T07 2.1.
      final files = _MemoryFiles();
      final storage = _CapturingStorage(paths: _paths(), files: files);
      final store = SessionStore(storage: storage);
      final view = ViewState.restore(<String, Object?>{},
          currentNonEmpty: false, settingsScrollMaximum: 764);
      final saved = await store.save(_library(), _player(), view);
      expect(saved, isTrue);
      expect(storage.capturedPath, joinPath(_paths().dataDirectory, 'session.json'));
      expect(storage.capturedLimit, SessionStore.sessionLimitBytes);
      expect(storage.capturedLimit, 67108864);
      final encoded = jsonEncode(storage.capturedJson);
      final decoded = jsonDecode(encoded) as Map<String, Object?>;
      expect(decoded.keys.toList(),
          orderedEquals(<String>['version', 'library', 'player', 'view']));
      expect(decoded['version'], 1);
      expect((decoded['view'] as Map<String, Object?>).keys.toList(),
          orderedEquals(ViewState.viewKeys));
      expect((decoded['player'] as Map<String, Object?>).keys, hasLength(7));
      expect(decoded['library'], isA<Map<String, Object?>>());
    });

    test('return value is the writer result', () async {
      // over 64 MiB the writer returns false and keeps the old file (T07 2.5);
      // the store must not swallow or invert that.
      final files = _MemoryFiles();
      final storage = _FailingStorage(paths: _paths(), files: files);
      final store = SessionStore(storage: storage);
      final saved = await store.save(
        _library(),
        _player(),
        ViewState.restore(<String, Object?>{},
            currentNonEmpty: false, settingsScrollMaximum: 764),
      );
      expect(saved, isFalse);
      expect(storage.limitBytesSeen, SessionStore.sessionLimitBytes);
    });
  });

  group('real file system round trip (Directory.systemTemp only)', () {
    late Directory root;
    late AppStorage storage;

    setUp(() {
      root = Directory.systemTemp.createTempSync('rhine-t26-s02-');
      storage = AppStorage(
        paths: AppStoragePaths(
          dataDirectory: joinPath(root.path, 'data'),
          cacheDirectory: joinPath(root.path, 'cache'),
          temporaryDirectory: joinPath(root.path, 'tmp'),
          executableDirectory: joinPath(root.path, 'bin'),
        ),
      );
    });

    tearDown(() {
      if (root.existsSync()) {
        root.deleteSync(recursive: true);
      }
    });

    test('save then load restores the same view and library', () async {
      final store = SessionStore(storage: storage);
      final view = ViewState.restore(
        <String, Object?>{
          'mode': 'detail',
          'selected': 41,
          'tab': 'history',
          'modal': 'settings',
          'queueOffset': -1,
          'settingsScroll': 99999,
          'query': 'q',
          'groupBy': '',
          'activeGroup': 'g',
          'artistTab': 'albums',
          'listOffset': 2,
          'trackOffset': 3,
          'bodyOffset': 4,
          'musicCollection': 9,
          'trackListMode': true,
          'lyricsMode': true,
        },
        currentNonEmpty: true,
        settingsScrollMaximum: 764,
      );
      expect(
        await store.save(
          _library(current: <String, Object?>{'id': 'siren-1'}),
          _player(),
          view,
        ),
        isTrue,
      );
      expect(File(storage.sessionPath).existsSync(), isTrue);

      final result =
          await store.loadForRestore(_identity, playbackConnection: false);
      expect(result.loaded, isTrue);
      expect(result.view!.selected, 39);
      expect(result.view!.tab, 'history');
      expect(result.view!.modal, 'settings');
      expect(result.view!.settingsScroll, 764.0);
      expect(result.view!.musicCollection, 4);
      expect(result.view!.mode, 'detail');
      expect(result.library!['current'], <String, Object?>{'id': 'siren-1'});
      expect(result.failureReason, isNull);
    });

    test('a gate failure never deletes the file', () async {
      final store = SessionStore(storage: storage);
      await store.save(
        _library(),
        _player(),
        ViewState.restore(<String, Object?>{},
            currentNonEmpty: false, settingsScrollMaximum: 764),
      );
      final before = File(storage.sessionPath).readAsBytesSync();

      final versioned = Map<String, Object?>.from(
          jsonDecode(utf8.decode(before)) as Map<String, Object?>)
        ..['version'] = 2;
      File(storage.sessionPath).writeAsBytesSync(utf8.encode(jsonEncode(versioned)));
      final result =
          await store.loadForRestore(_identity, playbackConnection: false);
      expect(result.failureReason, 'version');
      expect(File(storage.sessionPath).existsSync(), isTrue);
      expect(result.view, isNull);
      expect(result.player, isNull);
    });

    test('an oversize archive is kept and reported', () async {
      // NativeApplication.cpp:64-68: size > 64 MiB is not read, and the memory
      // case is what the Qt code does — nothing is deleted.
      final store = SessionStore(storage: storage);
      final file = File(storage.sessionPath);
      await file.parent.create(recursive: true);
      await file.writeAsBytes(Uint8List(SessionStore.sessionLimitBytes + 1));
      final result =
          await store.loadForRestore(_identity, playbackConnection: false);
      expect(result.failureReason, 'oversize');
      expect(file.existsSync(), isTrue);
      expect(file.lengthSync(), SessionStore.sessionLimitBytes + 1);
    });

    test('a write above the 64 MiB cap keeps the old archive byte for byte',
        () async {
      // MusicSession.cpp:276-282: over 64 MiB the old file survives untouched
      // (the cap itself lives in AppStorage.writeJsonAtomic, T26-S01).
      final store = SessionStore(storage: storage);
      final file = File(storage.sessionPath);
      await file.parent.create(recursive: true);
      const oldBytes = <int>[123, 125];
      await file.writeAsBytes(oldBytes);
      // ~67 MiB of JSON; this is the only allocation-heavy expectation in the
      // file and it exists to prove the cap is enforced before any truncate.
      final raw = Uint8List(67108865);
      raw.fillRange(0, raw.length, 120);
      final huge = _library();
      (huge['sources'] as List<Object?>)[0] = <String, Object?>{
        'items': <Object?>[String.fromCharCodes(raw)],
      };
      final saved = await store.save(
        huge,
        _player(),
        ViewState.restore(<String, Object?>{},
            currentNonEmpty: false, settingsScrollMaximum: 764),
      );
      expect(saved, isFalse);
      expect(file.readAsBytesSync(), orderedEquals(oldBytes));
    });
  });

  group('failure reason enum', () {
    test('exposes the frozen reason strings', () {
      expect(
        kSessionFailureReasons,
        orderedEquals(<String>[
          'missing',
          'unreadable',
          'oversize',
          'invalid-json',
          'version',
          'provider-mismatch',
          'edition-mismatch',
          'uid-mismatch',
          'sources-length',
          'selected-physical',
          'directories-too-many',
        ]),
      );
    });
  });

  // QJsonValue::toInt(defaultValue) is a 32-bit conversion
  // (qjsonvalue.cpp:686-705 + qnumeric_p.h:264-289). These cases pin the
  // divergences the old 2^53 bound allowed: an out-of-int32 number must take
  // the Qt default, never saturate to the clamp bound.
  group('QJsonValue::toInt 32-bit range', () {
    ViewState restoreView(Map<String, Object?> raw, {int maximum = 764}) =>
        ViewState.restore(
          raw,
          currentNonEmpty: false,
          settingsScrollMaximum: maximum,
        );

    test('view.selected out of int32 falls back to 0, not 39', () {
      // MusicSession.cpp:260 clamp(view["selected"].toInt(), 0, 39).
      expect(restoreView(<String, Object?>{'selected': 1e15}).selected, 0);
      expect(restoreView(<String, Object?>{'selected': 3000000000}).selected, 0);
      expect(
        restoreView(<String, Object?>{'selected': 2147483648.0}).selected,
        0,
      );
      expect(
        restoreView(<String, Object?>{'selected': 9007199254740992.0}).selected,
        0,
      );
      // 2147483647 is still an int32: it clamps to 39.
      expect(
        restoreView(<String, Object?>{'selected': 2147483647.0}).selected,
        39,
      );
      expect(restoreView(<String, Object?>{'selected': 2147483647}).selected, 39);
      // A whole double inside the range converts unchanged.
      expect(restoreView(<String, Object?>{'selected': 2.0}).selected, 2);
      // The lower int32 bound is accepted; the 0..39 clamp maps it to 0 (the
      // same observable value the fallback would give, hence not independently
      // discriminating, but it records the boundary).
      expect(
        restoreView(<String, Object?>{'selected': -2147483648.0}).selected,
        0,
      );
      expect(
        restoreView(<String, Object?>{'selected': -2147483648.0}).selected,
        isNot(39),
      );
    });

    test('view.musicCollection out of int32 falls back to 1', () {
      // MusicSession.cpp:257 clamp(view["musicCollection"].toInt(1), 1, 4).
      expect(
        restoreView(<String, Object?>{'musicCollection': 1e15}).musicCollection,
        1,
      );
      expect(
        restoreView(<String, Object?>{'musicCollection': 3000000000})
            .musicCollection,
        1,
      );
      expect(
        restoreView(<String, Object?>{'musicCollection': 2147483648.0})
            .musicCollection,
        1,
      );
      expect(
        restoreView(<String, Object?>{'musicCollection': 2147483647.0})
            .musicCollection,
        4,
      );
      expect(
        restoreView(<String, Object?>{'musicCollection': 2.0}).musicCollection,
        2,
      );
    });

    test('view offsets use nonnegative(toInt()) (MusicSession.cpp:246,:254-256)',
        () {
      final huge = restoreView(<String, Object?>{
        'queueOffset': 1e15,
        'listOffset': 3000000000,
        'trackOffset': 2147483648.0,
        'bodyOffset': 9007199254740992.0,
      });
      expect(huge.queueOffset, 0);
      expect(huge.listOffset, 0);
      expect(huge.trackOffset, 0);
      expect(huge.bodyOffset, 0);
      final inRange = restoreView(<String, Object?>{
        'queueOffset': 2147483647.0,
        'listOffset': 2147483647,
      });
      expect(inRange.queueOffset, 2147483647);
      expect(inRange.listOffset, 2147483647);
    });

    test('view.settingsScroll is toDouble(), so a huge value still clamps', () {
      // MusicSession.cpp:247: std::clamp(view["settingsScroll"].toDouble(), 0.,
      // max). _clampDouble is not _toIntOr and must stay unaffected.
      expect(
        restoreView(<String, Object?>{'settingsScroll': 1e15}).settingsScroll,
        764.0,
      );
      expect(
        restoreView(<String, Object?>{'settingsScroll': 1e15}, maximum: 10)
            .settingsScroll,
        10.0,
      );
      expect(
        restoreView(<String, Object?>{'settingsScroll': 30.5}).settingsScroll,
        30.5,
      );
    });
  });

  group('library QJsonValue::toInt 32-bit range', () {
    test('groupLane out of int32 falls back to -1 (MusicSession.cpp:150)',
        () async {
      final saved = _library()..['groupLane'] = 3000000000;
      final result = await _store(_filesWith(_session(library: saved)))
          .loadForRestore(_identity, playbackConnection: false);
      expect(result.loaded, isTrue);
      expect(result.library!['groupLane'], -1);

      final high = _library()..['groupLane'] = 2147483647.0;
      final highResult = await _store(_filesWith(_session(library: high)))
          .loadForRestore(_identity, playbackConnection: false);
      expect(highResult.library!['groupLane'], 4);

      final exact = _library()..['groupLane'] = 2.0;
      final exactResult = await _store(_filesWith(_session(library: exact)))
          .loadForRestore(_identity, playbackConnection: false);
      expect(exactResult.library!['groupLane'], 2);
    });

    test('sources total/offset/row out of int32 fall back (MusicSession.cpp:109-111)',
        () async {
      final sources = <Object?>[
        <String, Object?>{
          'items': <Object?>['a', 'b', 'c'],
          'total': 1e15,
          'offset': 1e15,
          'row': 3000000000,
        },
        <String, Object?>{
          'items': <Object?>['a', 'b', 'c'],
          'offset': 2147483648.0,
          'row': 2147483648.0,
        },
        <String, Object?>{
          'items': <Object?>['a', 'b', 'c'],
          'offset': 2147483647.0,
          'row': 2147483647.0,
        },
        <String, Object?>{},
        <String, Object?>{},
      ];
      final result =
          await _store(_filesWith(_session(library: _library(sources: sources))))
              .loadForRestore(_identity, playbackConnection: false);
      expect(result.loaded, isTrue);
      final restored = (result.library!['sources'] as List<Object?>)
          .cast<Map<String, Object?>>();
      expect(restored[0]['total'], 3,
          reason: 'max(items.length = 3, nonnegative(toInt(1e15)) = 0)');
      expect(restored[0]['offset'], 0);
      expect(restored[0]['row'], 0);
      expect(restored[1]['offset'], 0);
      expect(restored[1]['row'], 0);
      expect(restored[2]['offset'], 2);
      expect(restored[2]['row'], 7);
    });

    test('directories fields out of int32 fall back (MusicSession.cpp:127-134)',
        () async {
      final entry = <String, Object?>{
        'songs': List<Object?>.filled(5, <String, Object?>{}),
        'ids': <Object?>['i1', 'i2', 'i3'],
        'index': 1e15,
        'cursor': 3000000000,
        'anchor': 1e15,
        'parentPhysical': 2147483648.0,
        'parentLane': 3000000000,
        'albumCursor': 1e15,
      };
      final result = await _store(_filesWith(
        _session(library: _library(directories: <Object?>[entry])),
      )).loadForRestore(_identity, playbackConnection: false);
      expect(result.loaded, isTrue);
      final restored = (result.library!['directories'] as List<Object?>).first
          as Map<String, Object?>;
      expect(restored['index'], 0);
      expect(restored['page'], 0);
      expect(restored['cursor'], 0);
      expect(restored['anchor'], 0);
      expect(restored['parentPhysical'], 0);
      expect(restored['parentLane'], 0);
      expect(restored['albumCursor'], 0);

      // The int32 upper bound still converts and only then clamps.
      final top = <String, Object?>{
        'songs': List<Object?>.filled(5, <String, Object?>{}),
        'ids': <Object?>['i1', 'i2', 'i3'],
        'index': 2147483647.0,
        'cursor': 2147483647,
        'anchor': 2147483647.0,
        'parentPhysical': 2147483647,
        'parentLane': 2147483647.0,
      };
      final topResult = await _store(_filesWith(
        _session(library: _library(directories: <Object?>[top])),
      )).loadForRestore(_identity, playbackConnection: false);
      final topEntry = (topResult.library!['directories'] as List<Object?>).first
          as Map<String, Object?>;
      expect(topEntry['index'], 4);
      expect(topEntry['cursor'], 3);
      expect(topEntry['anchor'], 39);
      expect(topEntry['parentPhysical'], 39);
      expect(topEntry['parentLane'], 4);
    });

    test('selectedLane/selectedPhysical out of int32 take the toInt default',
        () async {
      // MusicSession.cpp:93-94 toInt(-1): 3000000000 is rejected, so the gate
      // sees -1 — physical accepts "none selected", lane -1 fails the gate.
      final physicalFiles =
          _filesWith(_session(library: _library(selectedPhysical: 3000000000)));
      final physical = await _store(physicalFiles)
          .loadForRestore(_identity, playbackConnection: false);
      expect(physical.loaded, isTrue);
      expect(physical.library!['selectedPhysical'], -1);

      final laneFiles =
          _filesWith(_session(library: _library(selectedLane: 3000000000)));
      _expectKeptFailure(
        await _store(laneFiles)
            .loadForRestore(_identity, playbackConnection: false),
        'selected-physical',
        laneFiles,
      );
    });

    test('cursors/groupIndices/discover.offset use nonnegative(toInt())',
        () async {
      final library = _library();
      library.addAll(<String, Object?>{
        'searchCursor': 3000000000,
        'playlistCursor': 1e15,
        'albumCursor': 2147483648.0,
        'likedCursor': 1e15,
        'trackCursor': 3000000000,
        'groupIndices': <Object?>[3000000000, 2147483647, 1e15],
        'discover': <String, Object?>{'offset': 3000000000},
      });
      final result = await _store(_filesWith(_session(library: library)))
          .loadForRestore(_identity, playbackConnection: false);
      expect(result.loaded, isTrue);
      final restored = result.library!;
      expect(restored['searchCursor'], 0);
      expect(restored['playlistCursor'], 0);
      expect(restored['albumCursor'], 0);
      expect(restored['likedCursor'], 0);
      expect(restored['trackCursor'], 0);
      expect(restored['groupIndices'], orderedEquals(<Object?>[0, 2147483647, 0]));
      expect((restored['discover'] as Map<String, Object?>)['offset'], 0);
    });
  });
}

PlayerState _player() => const PlayerState(
      current: <String, Object?>{},
      queue: <Map<String, Object?>>[],
      index: 0,
      mode: 'off',
      position: 0,
      requested: false,
      preview: false,
    );

class _FailingStorage extends AppStorage {
  _FailingStorage({required super.paths, super.files});

  int? limitBytesSeen;

  @override
  Future<bool> writeJsonAtomic(
    String path,
    Object? json, {
    int limitBytes = kSessionLimitBytes,
  }) async {
    limitBytesSeen = limitBytes;
    return false;
  }
}
