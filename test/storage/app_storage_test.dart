/// UNEXECUTED tests for the storage path + file-IO foundation
/// (lib/data/storage/app_storage.dart).
///
/// Hard prohibition in this atom: tests are WRITTEN but NEVER EXECUTED
/// (no flutter test / dart test / analyze). Every case below is recorded as
/// UNEXECUTED in the T26-S01 report.
///
/// No test touches a real data directory: the business-level cases use the
/// in-memory fake defined in this file, and the IoFileSystemPort round-trip
/// uses a temporary directory created under Directory.systemTemp.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:rhine_music_database/data/storage/app_storage.dart';

// ---------------------------------------------------------------------------
// In-memory FileSystemPort fake (test-file only; never in lib/).
// ---------------------------------------------------------------------------

class _FakeFileSystem implements FileSystemPort {
  final Map<String, List<int>> files = <String, List<int>>{};
  final Set<String> directories = <String>{};

  /// Every port call in order, so the size-check-before-truncate invariant
  /// can be asserted.
  final List<String> log = <String>[];

  bool failWriteAtomic = false;

  /// Reports a valid size while the read itself fails; the only way to hit
  /// readCapped's second gate (bytes == null).
  bool failReadAll = false;

  int sizeOrNegativeCalls = 0;

  void seedFile(String path, List<int> bytes) {
    files[path] = List<int>.from(bytes);
  }

  void seedDirectory(String path) {
    directories.add(path);
  }

  @override
  Future<bool> exists(String path) async =>
      files.containsKey(path) || directories.contains(path);

  @override
  Future<int> sizeOrNegative(String path) async {
    sizeOrNegativeCalls += 1;
    log.add('sizeOrNegative:$path');
    final bytes = files[path];
    if (bytes == null) {
      return -1;
    }
    return bytes.length;
  }

  @override
  Future<List<int>?> readAll(String path) async {
    log.add('readAll:$path');
    if (failReadAll) {
      return null;
    }
    final bytes = files[path];
    if (bytes == null) {
      return null;
    }
    return List<int>.from(bytes);
  }

  @override
  Future<List<String>> list(String directory) async {
    if (!directories.contains(directory)) {
      return <String>[];
    }
    final entries = files.keys
        .where((path) => parentOf(path) == directory)
        .toList()
      ..sort();
    return entries;
  }

  @override
  Future<void> createDirectory(String directory) async {
    log.add('createDirectory:$directory');
    directories.add(directory);
  }

  @override
  Future<void> writeAtomic(String path, List<int> bytes) async {
    log.add('writeAtomic:$path');
    final directory = parentOf(path);
    final temp = '$path.rhine-tmp-fake';
    // The port itself guarantees "temporary file in the SAME directory".
    if (parentOf(temp) != directory) {
      throw StateError('temp file escaped the target directory');
    }
    if (failWriteAtomic) {
      files[temp] = List<int>.from(bytes);
      files.remove(temp); // the port cleans up its own temp on failure
      log.add('removeFile:$temp');
      throw const FileSystemException('simulated write failure');
    }
    files[temp] = List<int>.from(bytes);
    final committed = files.remove(temp)!;
    files[path] = committed; // rename over the target
  }

  @override
  Future<void> removeFile(String path) async {
    log.add('removeFile:$path');
    files.remove(path);
  }

  @override
  Future<void> removeTree(String path) async {
    log.add('removeTree:$path');
    files.removeWhere((key, _) => key == path || key.startsWith('$path/'));
    directories.removeWhere((dir) => dir == path || dir.startsWith('$path/'));
  }
}

String parentOf(String path) {
  final index = path.lastIndexOf('/');
  if (index < 0) {
    return '';
  }
  if (index == 0) {
    return '/';
  }
  return path.substring(0, index);
}

bool sameBytes(List<int> left, List<int> right) {
  if (identical(left, right)) {
    return true;
  }
  if (left.length != right.length) {
    return false;
  }
  for (var index = 0; index < left.length; index += 1) {
    if (left[index] != right[index]) {
      return false;
    }
  }
  return true;
}

/// JSON whose utf8(jsonEncode(...)) length is exactly [totalBytes].
/// '{"pad":"' is 8 bytes and the closing '"}' is 2 bytes.
Map<String, Object?> jsonOfEncodedLength(int totalBytes) {
  const int overhead = 10;
  return <String, Object?>{'pad': 'a' * (totalBytes - overhead)};
}

const int _sixtyMiB = 60 * 1024 * 1024;

const AppStoragePaths _paths = AppStoragePaths(
  dataDirectory: '/injected/verbatim/data',
  cacheDirectory: '/injected/verbatim/cache',
  temporaryDirectory: '/injected/verbatim/temp',
  executableDirectory: '/injected/verbatim/exe',
);

void main() {
  group('joinPath', () {
    test('joins base and leaf with exactly one separator', () {
      expect(joinPath('/injected/data', 'session.json'),
          '/injected/data/session.json');
    });

    test('collapses a trailing separator on base', () {
      expect(joinPath('/injected/data/', 'session.json'),
          '/injected/data/session.json');
      expect(joinPath('/injected/data//', 'session.json'),
          '/injected/data/session.json');
    });

    test('collapses a leading separator on leaf', () {
      expect(joinPath('/injected/data', '/session.json'),
          '/injected/data/session.json');
    });

    test('empty base yields the leaf unchanged', () {
      expect(joinPath('', 'session.json'), 'session.json');
      expect(joinPath('', ''), '');
    });

    test('keeps separators inside the leaf', () {
      expect(joinPath('/injected/data', 'collections/siren.json'),
          '/injected/data/collections/siren.json');
    });

    test('never produces a doubled or a missing separator', () {
      const bases = <String>['', '/', '/a', '/a/', '/a//', 'a', 'a/'];
      const leaves = <String>['', 'b', '/b', 'c/d', '/c/d'];
      for (final base in bases) {
        for (final leaf in leaves) {
          final joined = joinPath(base, leaf);
          expect(joined.contains('//'), isFalse,
              reason: 'doubled separator for base=$base leaf=$leaf');
          if (base.isNotEmpty && leaf.isNotEmpty) {
            final strippedBase = base.replaceAll(RegExp(r'/+$'), '');
            final strippedLeaf = leaf.replaceAll(RegExp(r'^/+'), '');
            if (strippedBase.isNotEmpty && strippedLeaf.isNotEmpty) {
              expect(joined, '$strippedBase/$strippedLeaf',
                  reason: 'missing separator for base=$base leaf=$leaf');
            }
          }
        }
      }
    });
  });

  group('size limits', () {
    test('session limit is exactly 64 MiB and strictly greater-than on write',
        () {
      expect(kSessionLimitBytes, 67108864);
      expect(kSessionLimitBytes, 64 * 1024 * 1024);
      expect(kSessionLimitBytes + 1, 67108865);
    });

    test('collection limit is exactly 16 MiB', () {
      expect(kCollectionLimitBytes, 16777216);
      expect(kCollectionLimitBytes, 16 * 1024 * 1024);
    });
  });

  group('injected directories', () {
    test('file paths derive from the injected data directory only', () {
      final storage = AppStorage(paths: _paths, files: _FakeFileSystem());
      expect(storage.sessionPath, '/injected/verbatim/data/session.json');
      expect(storage.playbackSessionPath,
          '/injected/verbatim/data/playback-session.json');
      expect(storage.credentialPath,
          '/injected/verbatim/data/account.credential');
      expect(storage.qqDevicePath, '/injected/verbatim/data/qq-device.json');
      expect(storage.kugouDevicePath,
          '/injected/verbatim/data/kugou-device.json');
      expect(storage.collectionsDirectory,
          '/injected/verbatim/data/collections');
      expect(storage.sirenCollectionPath,
          '/injected/verbatim/data/collections/siren.json');
    });

    test('kugou uses ONE device file for both editions', () {
      final storage = AppStorage(paths: _paths, files: _FakeFileSystem());
      expect(storage.kugouDevicePath.contains('standard'), isFalse);
      expect(storage.kugouDevicePath.contains('lite'), isFalse);
      expect(storage.kugouDevicePath, endsWith('kugou-device.json'));
    });

    test('nothing is hardcoded to /data/data and injected values are verbatim',
        () {
      final storage = AppStorage(paths: _paths, files: _FakeFileSystem());
      for (final path in <String>[
        storage.sessionPath,
        storage.playbackSessionPath,
        storage.credentialPath,
        storage.qqDevicePath,
        storage.kugouDevicePath,
        storage.collectionsDirectory,
        storage.sirenCollectionPath,
      ]) {
        expect(path.startsWith('/data/data/'), isFalse);
        expect(path.startsWith(_paths.dataDirectory), isTrue);
      }
    });

    test('injected directory values are carried through verbatim', () {
      // Every slot holds a distinct value, so a getter that returned the wrong
      // field could not satisfy these assertions. The previous version
      // compared the accessor with the very object that had been injected.
      const other = AppStoragePaths(
        dataDirectory: '/other/data',
        cacheDirectory: '/other/cache',
        temporaryDirectory: '/other/tmp',
        executableDirectory: '/other/bin',
      );
      final storage = AppStorage(paths: other, files: _FakeFileSystem());

      expect(storage.paths.dataDirectory, '/other/data');
      expect(storage.paths.cacheDirectory, '/other/cache');
      expect(storage.paths.temporaryDirectory, '/other/tmp');
      expect(storage.paths.executableDirectory, '/other/bin');
      // The derived paths follow that same instance, never a default value.
      expect(storage.sessionPath, '/other/data/session.json');
      expect(storage.collectionsDirectory, '/other/data/collections');
    });
  });

  group('writeJsonAtomic', () {
    test('60 MiB payload writes atomically and replaces the old content', () {
      final fs = _FakeFileSystem()
        ..seedFile('/injected/verbatim/data/session.json',
            utf8.encode('{"old":true}'));
      final storage = AppStorage(paths: _paths, files: fs);
      final payload = jsonOfEncodedLength(_sixtyMiB);
      final expected = utf8.encode(jsonEncode(payload));
      expect(expected.length, _sixtyMiB);
      expect(expected.length <= kSessionLimitBytes, isTrue);

      final ok = await storage.writeJsonAtomic(
          '/injected/verbatim/data/session.json', payload);

      expect(ok, isTrue);
      expect(
          sameBytes(fs.files['/injected/verbatim/data/session.json']!, expected),
          isTrue);
      // Parent directory created first, then exactly one atomic write. Both
      // indices are asserted to be present: indexOf returns -1 for a missing
      // entry, so a bare "-1 < index" comparison would still pass.
      final createIndex =
          fs.log.indexOf('createDirectory:/injected/verbatim/data');
      final writeIndex =
          fs.log.indexOf('writeAtomic:/injected/verbatim/data/session.json');
      expect(createIndex, isNonNegative);
      expect(writeIndex, isNonNegative);
      expect(createIndex, lessThan(writeIndex));
    });

    test('exactly 67108864 bytes is accepted (limit is strictly greater-than)',
        () {
      final fs = _FakeFileSystem();
      final storage = AppStorage(paths: _paths, files: fs);
      final payload = jsonOfEncodedLength(kSessionLimitBytes);
      final expected = utf8.encode(jsonEncode(payload));
      expect(expected.length, 67108864);

      final ok = await storage.writeJsonAtomic(
          '/injected/verbatim/data/session.json', payload);

      expect(ok, isTrue);
      expect(
          sameBytes(fs.files['/injected/verbatim/data/session.json']!, expected),
          isTrue);
    });

    test('67108865 bytes is rejected and the old file stays byte-identical',
        () {
      final oldContent = utf8.encode('{"version":1,"library":{}}');
      final fs = _FakeFileSystem()
        ..seedFile('/injected/verbatim/data/session.json', oldContent)
        ..seedDirectory('/injected/verbatim/data');
      final storage = AppStorage(paths: _paths, files: fs);
      final payload = jsonOfEncodedLength(67108865);
      expect(utf8.encode(jsonEncode(payload)).length, 67108865);

      final ok = await storage.writeJsonAtomic(
          '/injected/verbatim/data/session.json', payload);

      expect(ok, isFalse);
      expect(
          sameBytes(
              fs.files['/injected/verbatim/data/session.json']!, oldContent),
          isTrue);
      // The size check happens BEFORE any create/truncate: the port was never
      // asked to write and no directory was touched.
      expect(fs.log.any((entry) => entry.startsWith('writeAtomic')), isFalse);
      expect(
          fs.log.any((entry) => entry.startsWith('createDirectory')), isFalse);
    });

    test('offline write returns false and touches nothing', () {
      final oldContent = utf8.encode('{"old":1}');
      final fs = _FakeFileSystem()
        ..seedFile('/injected/verbatim/data/session.json', oldContent);
      final storage = AppStorage(paths: _paths, files: fs, offline: true);

      final ok = await storage.writeJsonAtomic(
          '/injected/verbatim/data/session.json', <String, Object?>{'new': 2});

      expect(ok, isFalse);
      expect(
          sameBytes(
              fs.files['/injected/verbatim/data/session.json']!, oldContent),
          isTrue);
      expect(fs.log, isEmpty);
      expect(fs.sizeOrNegativeCalls, 0);
    });

    test('serialization failure leaves the old file and writes no empty file',
        () {
      final oldContent = utf8.encode('{"old":1}');
      final fs = _FakeFileSystem()
        ..seedFile('/injected/verbatim/data/session.json', oldContent);
      final storage = AppStorage(paths: _paths, files: fs);

      final ok = await storage.writeJsonAtomic(
          '/injected/verbatim/data/session.json', Object());

      expect(ok, isFalse);
      expect(
          sameBytes(
              fs.files['/injected/verbatim/data/session.json']!, oldContent),
          isTrue);
      expect(fs.log.any((entry) => entry.startsWith('writeAtomic')), isFalse);
    });

    test('IO failure leaves the old file untouched', () {
      final oldContent = utf8.encode('{"old":1}');
      final fs = _FakeFileSystem()
        ..seedFile('/injected/verbatim/data/session.json', oldContent)
        ..failWriteAtomic = true;
      final storage = AppStorage(paths: _paths, files: fs);

      final ok = await storage.writeJsonAtomic(
          '/injected/verbatim/data/session.json', <String, Object?>{'new': 2});

      expect(ok, isFalse);
      expect(
          sameBytes(
              fs.files['/injected/verbatim/data/session.json']!, oldContent),
          isTrue);
      // The port was asked exactly once; temp-file handling belongs to the
      // port contract, and the real port's cleanup is tested below under
      // Directory.systemTemp.
      expect(
          fs.log.where((entry) => entry.startsWith('writeAtomic')).length, 1);
    });

    test('output is compact UTF-8 with map insertion order preserved', () {
      final fs = _FakeFileSystem();
      final storage = AppStorage(paths: _paths, files: fs);

      final ok = await storage.writeJsonAtomic('/injected/verbatim/data/session.json',
          <String, Object?>{'b': 1, 'a': 'x'});

      expect(ok, isTrue);
      final text = utf8.decode(fs.files['/injected/verbatim/data/session.json']!);
      expect(text, '{"b":1,"a":"x"}');
      expect(text.contains(RegExp(r'\s')), isFalse);
    });

    test('an explicit limitBytes override is honoured', () async {
      final fs = _FakeFileSystem();
      final storage = AppStorage(paths: _paths, files: fs);
      const target = '/injected/verbatim/data/collections/siren.json';
      final payload = <String, Object?>{'a': 1}; // utf8(jsonEncode) == 7 bytes

      // 7 > 6: rejected before any create or write, nothing on disk.
      expect(await storage.writeJsonAtomic(target, payload, limitBytes: 6),
          isFalse);
      expect(fs.files.containsKey(target), isFalse);
      expect(fs.log.any((entry) => entry.startsWith('writeAtomic')), isFalse);
      expect(
          fs.log.any((entry) => entry.startsWith('createDirectory')), isFalse);

      // Exactly at the override limit is accepted (strictly greater-than).
      expect(await storage.writeJsonAtomic(target, payload, limitBytes: 7),
          isTrue);
      expect(fs.files.containsKey(target), isTrue);
    });

    test('a target with no parent directory skips createDirectory', () async {
      final fs = _FakeFileSystem();
      final storage = AppStorage(paths: _paths, files: fs);

      final ok = await storage.writeJsonAtomic(
          'session.json', <String, Object?>{'a': 1});

      expect(ok, isTrue);
      expect(
          fs.log.any((entry) => entry.startsWith('createDirectory')), isFalse);
      expect(fs.files['session.json'], isNotNull);
    });
  });

  group('readCapped', () {
    test('missing file returns null', () async {
      final fs = _FakeFileSystem();
      final storage = AppStorage(paths: _paths, files: fs);
      expect(
          await storage.readCapped(
              '/injected/verbatim/data/session.json', kSessionLimitBytes),
          isNull);
    });

    test('size 67108864 is readable, 67108865 returns null', () async {
      final fs = _FakeFileSystem()
        ..seedFile('/injected/verbatim/data/at-limit.json',
            List<int>.filled(kSessionLimitBytes, 0x41))
        ..seedFile('/injected/verbatim/data/over-limit.json',
            List<int>.filled(kSessionLimitBytes + 1, 0x41));
      final storage = AppStorage(paths: _paths, files: fs);

      final read = await storage.readCapped(
          '/injected/verbatim/data/at-limit.json', kSessionLimitBytes);
      expect(read, isNotNull);
      expect(read!.length, 67108864);

      expect(
          await storage.readCapped(
              '/injected/verbatim/data/over-limit.json', kSessionLimitBytes),
          isNull);
    });

    test('size fits but the read fails: the second gate returns null', () async {
      final fs = _FakeFileSystem()
        ..seedFile('/injected/verbatim/data/unreadable.json',
            utf8.encode('{"a":1}'))
        ..failReadAll = true;
      final storage = AppStorage(paths: _paths, files: fs);

      expect(
          await storage.readCapped(
              '/injected/verbatim/data/unreadable.json', kSessionLimitBytes),
          isNull);
      // A failed read never deletes anything.
      expect(fs.files.containsKey('/injected/verbatim/data/unreadable.json'),
          isTrue);
      expect(fs.log.any((entry) => entry.startsWith('removeFile')), isFalse);
    });

    test('reads never delete the file', () async {
      final fs = _FakeFileSystem()
        ..seedFile('/injected/verbatim/data/session.json', utf8.encode('{"a":1}'))
        ..seedFile('/injected/verbatim/data/big.json',
            List<int>.filled(kSessionLimitBytes + 1, 0));
      final storage = AppStorage(paths: _paths, files: fs);

      await storage.readCapped(
          '/injected/verbatim/data/session.json', kSessionLimitBytes);
      await storage.readCapped(
          '/injected/verbatim/data/big.json', kSessionLimitBytes);

      expect(fs.files.containsKey('/injected/verbatim/data/session.json'),
          isTrue);
      expect(fs.files.containsKey('/injected/verbatim/data/big.json'), isTrue);
      expect(fs.log.any((entry) => entry.startsWith('removeFile')), isFalse);
      expect(fs.log.any((entry) => entry.startsWith('removeTree')), isFalse);
    });

    test('collection cap of 16 MiB is applied when passed', () async {
      final fs = _FakeFileSystem()
        ..seedFile('/injected/verbatim/data/collections/siren.json',
            List<int>.filled(kCollectionLimitBytes + 1, 0));
      final storage = AppStorage(paths: _paths, files: fs);
      expect(
          await storage.readCapped(
              '/injected/verbatim/data/collections/siren.json',
              kCollectionLimitBytes),
          isNull);
    });
  });

  group('IoFileSystemPort under Directory.systemTemp', () {
    late Directory root;

    setUp(() {
      root = Directory.systemTemp.createTempSync('app_storage_test_');
    });

    tearDown(() {
      if (root.existsSync()) {
        root.deleteSync(recursive: true);
      }
    });

    test('round-trips under Directory.systemTemp (never a real data dir)',
        () async {
      const fs = IoFileSystemPort();
      final dir = '${root.path}/injected/data';
      final target = '$dir/session.json';

      expect(await fs.sizeOrNegative(target), -1);
      expect(await fs.readAll(target), isNull);
      expect(await fs.exists(target), isFalse);

      await fs.createDirectory(dir);
      await fs.writeAtomic(target, utf8.encode('{"version":1}'));

      expect(await fs.exists(target), isTrue);
      expect(await fs.sizeOrNegative(target), 13);
      expect(utf8.decode((await fs.readAll(target))!), '{"version":1}');

      // Replace atomically and leave no temporary file behind.
      await fs.writeAtomic(target, utf8.encode('{"version":1,"x":2}'));
      final entries = await fs.list(dir);
      expect(entries.length, 1);
      expect(entries.single, target);

      await fs.removeFile(target);
      expect(await fs.exists(target), isFalse);
      await fs.removeFile(target); // missing is not an error

      await fs.removeTree(dir);
      expect(await fs.exists(dir), isFalse);
      await fs.removeTree(dir); // missing is not an error
    });

    test('real port leaves no temp file behind when the write cannot start',
        () async {
      const fs = IoFileSystemPort();
      final target = '${root.path}/missing/dir/session.json';

      // The parent directory does not exist, so the temporary file can never
      // be created; the failure must not leave the target or any *.rhine-tmp-*
      // entry behind.
      await expectLater(
        fs.writeAtomic(target, utf8.encode('{"x":1}')),
        throwsA(isA<FileSystemException>()),
      );

      expect(File(target).existsSync(), isFalse);
      final leftovers = root
          .listSync(recursive: true)
          .map((entity) => entity.path)
          .where((path) => path.contains('rhine-tmp'))
          .toList();
      expect(leftovers, isEmpty);
    });
  });
}
