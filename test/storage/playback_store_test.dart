// T26-S03 static tests: background-playback persistence and player normalization.
//
// NOT EXECUTED: flutter/dart run|test|analyze|build are forbidden in this task, so RED
// and GREEN are both recorded as NOT EXECUTED. Every case runs against an in-memory
// FileSystemPort - the real Android data directory is never touched.
//
// Spec: Qt/src/PlaybackService.cpp:419-448 (read precedence, save), MusicPlayer.cpp:749-779
// (player object + position/mode/provider gates), PlaybackQueue.cpp:14-30,36-38,130-147,398-418
// (identity, sanitising, pre-filter index, deferred, append on unknown track).

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:rhine_music_database/data/storage/app_storage.dart';
import 'package:rhine_music_database/data/storage/playback_store.dart';

class FakeFiles implements FileSystemPort {
  final Map<String, List<int>> files = <String, List<int>>{};
  final List<String> removedFiles = <String>[];
  final List<String> removedTrees = <String>[];
  final List<String> writes = <String>[];
  bool failReads = false;
  bool failWrites = false;

  @override
  Future<bool> exists(String path) async => files.containsKey(path);

  @override
  Future<int> sizeOrNegative(String path) async => files[path]?.length ?? -1;

  @override
  Future<List<int>?> readAll(String path) async {
    if (failReads) {
      throw StateError('read denied');
    }
    final bytes = files[path];
    return bytes == null ? null : List<int>.of(bytes);
  }

  @override
  Future<List<String>> list(String directory) async => const <String>[];

  @override
  Future<void> createDirectory(String directory) async {}

  @override
  Future<void> writeAtomic(String path, List<int> bytes) async {
    if (failWrites) {
      throw StateError('write denied');
    }
    files[path] = List<int>.of(bytes);
    writes.add(path);
  }

  @override
  Future<void> removeFile(String path) async {
    removedFiles.add(path);
    files.remove(path);
  }

  @override
  Future<void> removeTree(String directory) async {
    removedTrees.add(directory);
  }
}

AppStorage storageWith(FakeFiles files, {bool offline = false}) => AppStorage(
      paths: const AppStoragePaths(
        dataDirectory: '/runtime-data',
        cacheDirectory: '/runtime-cache',
        temporaryDirectory: '/runtime-temp',
        executableDirectory: '/runtime-app',
      ),
      files: files,
      offline: offline,
    );

String sessionPath = '/runtime-data/session.json';
String playbackPath = '/runtime-data/playback-session.json';

List<int> encode(Object? value) => utf8.encode(jsonEncode(value));

Map<String, Object?> song(String id, {String provider = 'netease', String kind = 'song'}) =>
    <String, Object?>{'kind': kind, 'id': id, 'provider': provider, 'title': 't-' + id};

Map<String, Object?> player({
  Object? current = const <String, Object?>{},
  Object? queue = const <Object?>[],
  Object? index = -1,
  Object? mode = 'all',
  Object? position = 1.0,
  Object? requested = false,
  Object? preview = false,
}) =>
    <String, Object?>{
      'current': current,
      'queue': queue,
      'index': index,
      'mode': mode,
      'position': position,
      'requested': requested,
      'preview': preview,
    };

void main() {
  group('playback-session.json read precedence (PlaybackService.cpp:419-436)', () {
    test('the playback file wins over session.json', () async {
      final files = FakeFiles()
        ..files[sessionPath] = encode(<String, Object?>{'version': 1, 'player': player(mode: 'off')})
        ..files[playbackPath] = encode(player(mode: 'one', position: 12.5));
      final store = PlaybackStore(storage: storageWith(files));
      final loaded = await store.load(currentProvider: 'netease');
      expect(loaded, isNotNull);
      expect(loaded!.mode, 'one');
      expect(loaded.position, 12.5);
    });

    test('session.json top-level player is used only when the playback file is absent', () async {
      final files = FakeFiles()
        ..files[sessionPath] = encode(<String, Object?>{'version': 1, 'player': player(mode: 'one', position: 12.5)});
      final store = PlaybackStore(storage: storageWith(files));
      final loaded = await store.load(currentProvider: 'netease');
      expect(loaded, isNotNull);
      expect(loaded!.mode, 'one');
      expect(loaded.position, 12.5);
    });

    test('a corrupt playback file does NOT fall back to a valid session.json', () async {
      final files = FakeFiles()
        ..files[sessionPath] = encode(<String, Object?>{'version': 1, 'player': player(mode: 'one')})
        ..files[playbackPath] = utf8.encode('{ this is not json');
      final store = PlaybackStore(storage: storageWith(files));
      expect(await store.load(currentProvider: 'netease'), isNull);
      expect(files.files[playbackPath], isNotNull, reason: 'corrupt file must be kept');
    });

    test('an oversized playback file does NOT fall back either', () async {
      final files = FakeFiles()
        ..files[sessionPath] = encode(<String, Object?>{'version': 1, 'player': player(mode: 'one')})
        ..files[playbackPath] = List<int>.filled(PlaybackStore.sessionLimitBytes + 1, 0x20);
      final store = PlaybackStore(storage: storageWith(files));
      expect(await store.load(currentProvider: 'netease'), isNull);
      expect(files.files[playbackPath]!.length, PlaybackStore.sessionLimitBytes + 1);
    });

    test('an unreadable playback file yields null and keeps the file', () async {
      final files = FakeFiles()
        ..files[playbackPath] = encode(player())
        ..failReads = true;
      final store = PlaybackStore(storage: storageWith(files));
      expect(await store.load(currentProvider: 'netease'), isNull);
      expect(files.removedFiles, isEmpty);
      expect(files.removedTrees, isEmpty);
    });

    test('offline restores nothing', () async {
      final files = FakeFiles()..files[playbackPath] = encode(player());
      final store = PlaybackStore(storage: storageWith(files, offline: true));
      expect(await store.load(currentProvider: 'netease'), isNull);
    });

    test('the session cap is exactly 64 MiB', () {
      expect(PlaybackStore.sessionLimitBytes, 64 * 1024 * 1024);
      expect(PlaybackStore.sessionLimitBytes, 67108864);
    });
  });

  group('playback save (PlaybackService.cpp:438-448)', () {
    test('the player object is written verbatim to playback-session.json', () async {
      final files = FakeFiles();
      final store = PlaybackStore(storage: storageWith(files));
      final state = PlayerState(
        current: song('a'),
        queue: <Map<String, Object?>>[song('a')],
        index: 0,
        mode: 'one',
        position: 3.5,
        requested: true,
        preview: false,
      );
      expect(await store.save(state), isTrue);
      expect(files.writes, <String>[playbackPath]);
      final written = jsonDecode(utf8.decode(files.files[playbackPath]!)) as Map<String, Object?>;
      expect(written.keys.toList(),
          <String>['current', 'queue', 'index', 'mode', 'position', 'requested', 'preview']);
      expect(written['mode'], 'one');
      expect(files.files.containsKey(sessionPath), isFalse, reason: 'never write session.json');
    });

    test('an over-cap payload is refused and the previous file is untouched', () async {
      final files = FakeFiles()..files[playbackPath] = encode(player(mode: 'off'));
      final before = List<int>.of(files.files[playbackPath]!);
      final store = PlaybackStore(storage: storageWith(files));
      // 64 MiB + 1 of payload: the byte check runs BEFORE any create/truncate, so the
      // previous archive must survive byte for byte (PlaybackService.cpp:438-448).
      final huge = PlayerState(
        current: <String, Object?>{
          'kind': 'song',
          'id': 'x',
          'title': List<String>.filled(PlaybackStore.sessionLimitBytes + 1, 'x').join(),
        },
        queue: <Map<String, Object?>>[song('x')],
        index: 0,
        mode: 'all',
        position: 1,
        requested: false,
        preview: false,
      );
      expect(await store.save(huge), isFalse);
      expect(files.files[playbackPath], before);
    });

    test('offline never writes', () async {
      final files = FakeFiles();
      final store = PlaybackStore(storage: storageWith(files, offline: true));
      final state = PlayerState(
        current: const <String, Object?>{},
        queue: const <Map<String, Object?>>[],
        index: -1,
        mode: 'all',
        position: 0,
        requested: false,
        preview: false,
      );
      expect(await store.save(state), isFalse);
      expect(files.writes, isEmpty);
    });

    test('a failing port makes save return false instead of throwing', () async {
      // PlaybackService.cpp:438-448 commits and ignores the result; a refused write must
      // not escape as an exception into the playback runtime.
      final files = FakeFiles()..failWrites = true;
      final store = PlaybackStore(storage: storageWith(files));
      final state = PlayerState(
        current: const <String, Object?>{},
        queue: const <Map<String, Object?>>[],
        index: -1,
        mode: 'all',
        position: 0,
        requested: false,
        preview: false,
      );
      expect(await store.save(state), isFalse);
      expect(files.files, isEmpty);
      expect(files.removedFiles, isEmpty);
      expect(files.removedTrees, isEmpty);
    });
  });

  group('position gate (MusicPlayer.cpp:760-764)', () {
    test('a missing position aborts the whole restore', () {
      final raw = player()..remove('position');
      expect(normalizePlayer(raw, currentProvider: 'netease'), isNull);
    });

    test('a negative, over-limit or non-numeric position aborts the whole restore', () {
      expect(normalizePlayer(player(position: -0.5, mode: 'one'), currentProvider: 'netease'), isNull);
      expect(normalizePlayer(player(position: 1e12 + 1, mode: 'one'), currentProvider: 'netease'), isNull);
      expect(normalizePlayer(player(position: '12', mode: 'one'), currentProvider: 'netease'), isNull);
      expect(normalizePlayer(player(position: true, mode: 'one'), currentProvider: 'netease'), isNull);
    });

    test('the boundary value 1e12 itself is accepted', () {
      final loaded = normalizePlayer(player(position: 1e12), currentProvider: 'netease');
      expect(loaded, isNotNull);
      expect(loaded!.position, 1e12);
    });
  });

  group('mode whitelist and flags (MusicPlayer.cpp:765-766)', () {
    test('an unknown mode falls back to all', () {
      expect(normalizePlayer(player(mode: 'weird'), currentProvider: 'netease')!.mode, 'all');
      expect(normalizePlayer(player(mode: 3), currentProvider: 'netease')!.mode, 'all');
      expect(normalizePlayer(player(mode: 'shuffle'), currentProvider: 'netease')!.mode, 'shuffle');
    });

    test('non-boolean requested/preview are false', () {
      final loaded = normalizePlayer(player(requested: 1, preview: 'yes'), currentProvider: 'netease')!;
      expect(loaded.requested, isFalse);
      expect(loaded.preview, isFalse);
    });
  });

  group('queue sanitising (PlaybackQueue.cpp:14-30,36-38,398-418)', () {
    test('non-song and empty-id entries are dropped, duplicates keep the first', () {
      final raw = player(queue: <Object?>[
        song('a'),
        song('a'),
        <String, Object?>{'kind': 'album', 'id': 'z'},
        <String, Object?>{'kind': 'song', 'id': ''},
        song('b', provider: 'qq'),
      ]);
      final loaded = normalizePlayer(raw, currentProvider: 'netease')!;
      expect(loaded.queue.length, 2);
      expect(loaded.queue[0]['id'], 'a');
      expect(loaded.queue[1]['id'], 'b');
      expect(loaded.queue[1]['provider'], 'qq');
    });

    test('provider defaults to netease for identity, so a missing provider aliases netease', () {
      final raw = player(queue: <Object?>[
        <String, Object?>{'kind': 'song', 'id': 'a'},
        song('a'),
      ]);
      final loaded = normalizePlayer(raw, currentProvider: 'netease')!;
      expect(loaded.queue.length, 1);
    });

    test('deferred entries stay out of the complete queue', () {
      final deferred = song('a');
      deferred['deferred'] = true;
      final raw = player(queue: <Object?>[deferred, song('b')]);
      final loaded = normalizePlayer(raw, currentProvider: 'netease')!;
      expect(loaded.queue.length, 1);
      expect(loaded.queue.single['id'], 'b');
    });

    test('the saved index addresses the pre-filter array', () {
      // Row 0 is filtered out (not a song) and row 1 selects a valid track.
      final raw = player(queue: <Object?>[
        <String, Object?>{'kind': 'album', 'id': 'z'},
        song('b'),
      ], index: 1);
      final loaded = normalizePlayer(raw, currentProvider: 'netease')!;
      expect(loaded.queue.length, 1);
      expect(loaded.index, 0);
    });

    test('an out-of-range or deferred selection leaves no selection', () {
      expect(normalizePlayer(player(queue: <Object?>[song('b')], index: 9), currentProvider: 'netease')!.index, -1);
      expect(normalizePlayer(player(queue: <Object?>[song('b')], index: -1), currentProvider: 'netease')!.index, -1);
      final deferredEntry = song('b');
      deferredEntry['deferred'] = true;
      final deferredSelection = player(queue: <Object?>[deferredEntry], index: 0);
      final loaded = normalizePlayer(deferredSelection, currentProvider: 'netease')!;
      expect(loaded.queue, isEmpty);
      expect(loaded.index, -1);
    });

    test('restore() never mutates the caller payload', () {
      final raw = player(queue: <Object?>[song('a'), song('a')]);
      normalizePlayer(raw, currentProvider: 'netease');
      expect((raw['queue'] as List<Object?>).length, 2);
    });
  });

  group('current track gates (MusicPlayer.cpp:767-779)', () {
    test('an empty current restores only the queue', () {
      final loaded = normalizePlayer(player(queue: <Object?>[song('a')], index: 0), currentProvider: 'netease')!;
      expect(loaded.current, isEmpty);
      expect(loaded.queue.length, 1);
      expect(loaded.index, 0);
    });

    test('a non-song current aborts the whole restore', () {
      expect(
        normalizePlayer(player(current: <String, Object?>{'kind': 'album', 'id': 'a'}),
            currentProvider: 'netease'),
        isNull,
      );
    });

    test('a current from another provider aborts the whole restore', () {
      expect(
        normalizePlayer(player(current: song('a', provider: 'qq')), currentProvider: 'netease'),
        isNull,
      );
    });

    test('a current without a provider is treated as the running provider', () {
      final loaded = normalizePlayer(
        player(current: <String, Object?>{'kind': 'song', 'id': 'a'}, queue: <Object?>[song('a')]),
        currentProvider: 'netease',
      );
      expect(loaded, isNotNull);
      expect(loaded!.index, 0);
    });

    test('an unseen current is appended and selected, a known one is re-seated', () {
      final appended = normalizePlayer(
        player(current: song('c'), queue: <Object?>[song('a'), song('b')], index: 0),
        currentProvider: 'netease',
      )!;
      expect(appended.queue.map((t) => t['id']).toList(), <String>['a', 'b', 'c']);
      expect(appended.index, 2);

      final reseated = normalizePlayer(
        player(current: song('b'), queue: <Object?>[song('a'), song('b')], index: 0),
        currentProvider: 'netease',
      )!;
      expect(reseated.index, 1);
    });

    test('a current with an empty id is a queue no-op and keeps the restored row', () {
      // PlaybackQueue.cpp:140 appends only for kind == song && non-empty id; with an
      // empty id selectTrack returns and m_index keeps the row restore() picked.
      final loaded = normalizePlayer(
        player(
          current: <String, Object?>{'kind': 'song', 'id': '', 'provider': 'netease'},
          queue: <Object?>[song('a'), song('b')],
          index: 1,
        ),
        currentProvider: 'netease',
      )!;
      expect(loaded.queue.map((t) => t['id']).toList(), <String>['a', 'b']);
      expect(loaded.index, 1);
      expect(loaded.current['id'], '');
    });
  });

  group('encoding contract (MusicPlayer.cpp:749-757)', () {
    test('toJson emits exactly seven keys in Qt order', () {
      const state = PlayerState(
        current: <String, Object?>{},
        queue: <Map<String, Object?>>[],
        index: -1,
        mode: 'all',
        position: 0,
        requested: false,
        preview: false,
      );
      expect(state.toJson().keys.toList(),
          <String>['current', 'queue', 'index', 'mode', 'position', 'requested', 'preview']);
    });

    test('legacy deferred is never emitted', () {
      final loaded = normalizePlayer(player(queue: <Object?>[song('a')]), currentProvider: 'netease')!;
      final encoded = jsonEncode(loaded.toJson());
      expect(encoded.contains('deferred'), isFalse);
    });
  });
}
