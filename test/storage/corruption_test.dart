// T26-V3 corruption / no-data-loss tests for the storage domain.
// Spec: T07 FROZEN on-disk contract sections 0, 2.5, 4.2, 5.3, 9, 10.
// Contract under test: migration, first launch, offline, cache clear and parse failure
// must NEVER delete session.json, playback-session.json, collections or device files.
// STATIC ONLY: written but NEVER executed in this stage.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:rhine_music_database/data/storage/app_storage.dart';
import 'package:rhine_music_database/data/storage/playback_store.dart';
import 'package:rhine_music_database/data/storage/preference_store.dart';
import 'package:rhine_music_database/data/storage/session_store.dart';

/// Records every destructive call so a test can prove that no load path deletes user data.
class RecordingFileSystem implements FileSystemPort {
  RecordingFileSystem(this.inner);

  final FileSystemPort inner;
  final List<String> removedFiles = <String>[];
  final List<String> removedTrees = <String>[];
  final List<String> writes = <String>[];
  final List<String> reads = <String>[];
  bool failReads = false;

  @override
  Future<bool> exists(String path) => inner.exists(path);

  @override
  Future<int> sizeOrNegative(String path) => inner.sizeOrNegative(path);

  @override
  Future<List<int>?> readAll(String path) {
    reads.add(path);
    if (failReads) {
      return Future<List<int>?>.value(null);
    }
    return inner.readAll(path);
  }

  @override
  Future<List<String>> list(String directory) => inner.list(directory);

  @override
  Future<void> createDirectory(String directory) => inner.createDirectory(directory);

  @override
  Future<void> writeAtomic(String path, List<int> bytes) {
    writes.add(path);
    return inner.writeAtomic(path, bytes);
  }

  @override
  Future<void> removeFile(String path) {
    removedFiles.add(path);
    return inner.removeFile(path);
  }

  @override
  Future<void> removeTree(String path) {
    removedTrees.add(path);
    return inner.removeTree(path);
  }
}

class ThrowingPreferencePort implements PreferencePort {
  Object? readError = StateError('read denied');
  Object? writeError = StateError('write denied');

  // The panel store never receives an AppStorage/FileSystemPort (Qt stores these
  // values in QSettings, not in a data-directory file), so RecordingFileSystem's
  // logs can never move for this group. Count the calls the store itself makes on
  // its only collaborator instead: that is what "writes nothing" must mean here.
  int reads = 0;
  int writes = 0;
  int removes = 0;

  @override
  Future<String?> read(String key) {
    reads += 1;
    if (readError != null) {
      return Future<String?>.error(readError!);
    }
    return Future<String?>.value(null);
  }

  @override
  Future<void> write(String key, String value) {
    writes += 1;
    if (writeError != null) {
      return Future<void>.error(writeError!);
    }
    return Future<void>.value();
  }

  @override
  Future<void> remove(String key) {
    removes += 1;
    if (writeError != null) {
      return Future<void>.error(writeError!);
    }
    return Future<void>.value();
  }
}

void main() {
  late Directory temp;
  late RecordingFileSystem files;
  late AppStorage storage;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('t26_corrupt_');
    files = RecordingFileSystem(const IoFileSystemPort());
    storage = AppStorage(
      paths: AppStoragePaths(
        dataDirectory: temp.path,
        cacheDirectory: '${temp.path}/cache',
        temporaryDirectory: '${temp.path}/tmp',
        executableDirectory: '${temp.path}/exe',
      ),
      files: files,
    );
  });

  tearDown(() {
    if (temp.existsSync()) {
      temp.deleteSync(recursive: true);
    }
  });

  const SessionIdentity identity =
      SessionIdentity(provider: 'netease', edition: 'standard', uid: 'u1');

  Map<String, Object?> validSession() => <String, Object?>{
        'version': 1,
        'library': <String, Object?>{
          'provider': 'netease',
          'edition': 'standard',
          'uid': 'u1',
          'sources': List<Object?>.generate(
            5,
            (int i) => <String, Object?>{
              'items': <Object?>[],
              'total': 0,
              'offset': 0,
              'more': false,
              'row': 0,
            },
          ),
          'directories': <Object?>[],
          'current': <String, Object?>{},
          'selectedPhysical': -1,
          'selectedLane': 0,
        },
        'player': <String, Object?>{
          'current': <String, Object?>{},
          'queue': <Object?>[],
          'index': -1,
          'mode': 'all',
          'position': 0.0,
          'requested': false,
          'preview': false,
        },
        'view': <String, Object?>{
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
        },
      };

  void assertNothingDestroyed() {
    expect(files.removedFiles, isEmpty);
    expect(files.removedTrees, isEmpty);
  }

  group('no corruption path may delete or truncate user data', () {
    test('truncated JSON keeps the file and starts stateless', () async {
      final File target = File(storage.sessionPath);
      final String good = jsonEncode(validSession());
      await target.writeAsString(good.substring(0, good.length ~/ 2));
      final String before = await target.readAsString();
      final SessionStore store = SessionStore(storage: storage);
      final SessionRestoreResult r = await store.loadForRestore(identity, playbackConnection: false);
      expect(r.loaded, isFalse);
      expect(r.failureReason, 'invalid-json');
      expect(await target.readAsString(), before);
      assertNothingDestroyed();
    });

    test('garbage bytes keep the file', () async {
      final File target = File(storage.sessionPath);
      const String junk = '%%% not json at all %%%';
      await target.writeAsString(junk);
      final SessionStore store = SessionStore(storage: storage);
      final SessionRestoreResult r = await store.loadForRestore(identity, playbackConnection: false);
      expect(r.loaded, isFalse);
      expect(r.failureReason, 'invalid-json');
      expect(target.existsSync(), isTrue);
      // Byte for byte: garbage is kept, never rewritten or truncated (T07 0.2).
      expect(await target.readAsString(), junk);
      assertNothingDestroyed();
    });

    test('an empty file is not a session and is preserved', () async {
      final File target = File(storage.sessionPath);
      await target.writeAsString('');
      final SessionStore store = SessionStore(storage: storage);
      final SessionRestoreResult r = await store.loadForRestore(identity, playbackConnection: false);
      expect(r.loaded, isFalse);
      expect(r.failureReason, 'invalid-json');
      expect(await target.length(), 0);
      expect(target.existsSync(), isTrue);
      assertNothingDestroyed();
    });

    test('over 64 MiB is not parsed and the file is preserved', () async {
      final File target = File(storage.sessionPath);
      await target.writeAsString('y' * (64 * 1024 * 1024 + 1));
      final int before = await target.length();
      final SessionStore store = SessionStore(storage: storage);
      final SessionRestoreResult r = await store.loadForRestore(identity, playbackConnection: false);
      expect(r.loaded, isFalse);
      expect(r.failureReason, 'oversize');
      expect(await target.length(), before);
      assertNothingDestroyed();
    });

    test('permission denied / unreadable keeps the file and starts stateless', () async {
      final File target = File(storage.sessionPath);
      final String good = jsonEncode(validSession());
      await target.writeAsString(good);
      files.failReads = true;
      final SessionStore store = SessionStore(storage: storage);
      final SessionRestoreResult r = await store.loadForRestore(identity, playbackConnection: false);
      expect(r.loaded, isFalse);
      expect(r.failureReason, 'unreadable');
      expect(File(storage.sessionPath).existsSync(), isTrue);
      // The unreadable archive is kept byte for byte (T07 0.2: no data loss).
      expect(await target.readAsString(), good);
      assertNothingDestroyed();
    });

    test('a failed save never leaves a half written archive', () async {
      final File target = File(storage.sessionPath);
      await target.writeAsString(jsonEncode(validSession()));
      final String before = await target.readAsString();
      final SessionStore store = SessionStore(storage: storage);
      final SessionRestoreResult r = await store.loadForRestore(identity, playbackConnection: false);
      final Map<String, Object?> library = Map<String, Object?>.from(r.library!);
      library['keyword'] = 'z' * (64 * 1024 * 1024 + 1);
      expect(await store.save(library, r.player!, r.view!), isFalse);
      expect(await target.readAsString(), before);
      assertNothingDestroyed();
    });

    test('a corrupt session never logs out, never drops collections and keeps the device identity', () async {
      // Plan T26 Fail condition is "默认登出或丢收藏". Only an explicit sign-out may
      // touch credentials (T07 0.2 and 6.5), so a truncation / illegal-JSON
      // failure must leave account.credential, collections/siren.json and both
      // device identity files exactly as they were.
      const String credential = '{"netease":{"uid":"u1"}}';
      const String siren = '{"songs":[{"id":"t1"}]}';
      const String device = '{"device":"kugou-1"}';
      const String qqDevice = '{"device":"qq-1"}';
      await File(storage.credentialPath).writeAsString(credential);
      await Directory(storage.collectionsDirectory).create(recursive: true);
      await File(storage.sirenCollectionPath).writeAsString(siren);
      await File(storage.kugouDevicePath).writeAsString(device);
      await File(storage.qqDevicePath).writeAsString(qqDevice);

      final String truncated = jsonEncode(validSession()).substring(0, 60);
      final List<Map<String, String>> malformed = <Map<String, String>>[
        <String, String>{'body': '%%% not json at all %%%', 'reason': 'invalid-json'},
        <String, String>{'body': '', 'reason': 'invalid-json'},
        <String, String>{'body': truncated, 'reason': 'invalid-json'},
      ];
      final SessionStore store = SessionStore(storage: storage);
      for (final Map<String, String> entry in malformed) {
        final String body = entry['body']!;
        await File(storage.sessionPath).writeAsString(body);
        final SessionRestoreResult r = await store.loadForRestore(identity, playbackConnection: false);
        expect(r.loaded, isFalse, reason: entry['reason']);
        expect(r.failureReason, entry['reason']);
        expect(r.library, isNull);
        expect(r.view, isNull);
        expect(r.player, isNull);
        // Every byte of the rejected archive is still there ...
        expect(await File(storage.sessionPath).readAsString(), body, reason: entry['reason']);
        expect(await File(storage.sessionPath).length(), body.length);
        // ... and the account, the favourites and the device identity are untouched.
        expect(await File(storage.credentialPath).readAsString(), credential, reason: entry['reason']);
        expect(await File(storage.sirenCollectionPath).readAsString(), siren, reason: entry['reason']);
        expect(await File(storage.kugouDevicePath).readAsString(), device, reason: entry['reason']);
        expect(await File(storage.qqDevicePath).readAsString(), qqDevice, reason: entry['reason']);
        expect(File(storage.credentialPath).existsSync(), isTrue);
        expect(File(storage.sirenCollectionPath).existsSync(), isTrue);
        assertNothingDestroyed();
      }
    });
  });

  group('playback-session.json precedence (Qt/src/PlaybackService.cpp:419-436)', () {
    test('an existing but corrupt playback file does NOT fall back to session.json', () async {
      await File(storage.playbackSessionPath).writeAsString('{ broken');
      await File(storage.sessionPath).writeAsString(jsonEncode(<String, Object?>{
        'version': 1,
        'library': <String, Object?>{},
        'player': <String, Object?>{
          'current': <String, Object?>{},
          'queue': <Object?>[],
          'index': -1,
          'mode': 'all',
          'position': 1.0,
          'requested': false,
          'preview': false,
        },
        'view': <String, Object?>{},
      }));
      final PlaybackStore store = PlaybackStore(storage: storage);
      expect(await store.load(currentProvider: 'netease'), isNull);
      assertNothingDestroyed();
    });

    test('the legacy session.json player is used only when the playback file is absent', () async {
      await File(storage.sessionPath).writeAsString(jsonEncode(<String, Object?>{
        'version': 1,
        'library': <String, Object?>{},
        'player': <String, Object?>{
          'current': <String, Object?>{},
          'queue': <Object?>[],
          'index': -1,
          'mode': 'one',
          'position': 12.5,
          'requested': true,
          'preview': false,
        },
        'view': <String, Object?>{},
      }));
      final PlaybackStore store = PlaybackStore(storage: storage);
      final PlayerState? restored = await store.load(currentProvider: 'netease');
      expect(restored, isNotNull);
      expect(restored!.mode, 'one');
    });

    test('offline playback save writes nothing', () async {
      final AppStorage offlineStorage = AppStorage(
        paths: storage.paths,
        files: storage.files,
        offline: true,
      );
      final PlaybackStore store = PlaybackStore(storage: offlineStorage);
      const PlayerState player = PlayerState(
        current: <String, Object?>{},
        queue: <Map<String, Object?>>[],
        index: -1,
        mode: 'all',
        position: 0.0,
        requested: false,
        preview: false,
      );
      expect(await store.save(player), isFalse);
      expect(files.writes, isEmpty);
      assertNothingDestroyed();
    });
  });

  group('panel preferences are never treated as files (Qt/src/Host.cpp:1038-1118)', () {
    test('a failing platform port degrades to empty and writes nothing', () async {
      final ThrowingPreferencePort port = ThrowingPreferencePort();
      final PreferenceStore store = PreferenceStore(port: port);
      expect(await store.read('theme'), '');
      expect(await store.write('theme', 'dark'), isFalse);
      expect(port.reads, 1);
      expect(port.writes, 1);
      expect(port.removes, 0);
      // No `files.*` assertion here: PreferenceStore is built with `port:` only
      // (lib/data/storage/preference_store.dart:59) and never receives this
      // AppStorage/RecordingFileSystem, so files.writes and files.removedFiles can
      // never move for this group - such an expect() could not fail. The port
      // counters above are the only seam that can prove "writes nothing".
    });

    test('an absent key reads as empty and no default is persisted', () async {
      final ThrowingPreferencePort port = ThrowingPreferencePort()..readError = null;
      final PreferenceStore store = PreferenceStore(port: port);
      expect(await store.read('provider'), '');
      expect(port.reads, 1);
      expect(port.writes, 0);
      expect(port.removes, 0);
    });
  });
}
