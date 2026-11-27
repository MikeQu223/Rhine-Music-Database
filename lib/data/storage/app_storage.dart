/// Storage path + file-IO foundation for the Qt-Android -> Flutter parity port.
///
/// Faithful to Qt/src/AppStorage.cpp and Qt/src/AppStorage.h at the same
/// baseline (8ed3067b0812eb2612f7841ec127a6e8ca93231b). The runtime
/// data / cache / temporary / executable directories are INJECTED through
/// [AppStoragePaths]: the host wiring layer resolves the real Android
/// directories. This library never hardcodes /data/data/<package> and never
/// guesses a QSettings file name.
///
/// Qt contract mirrored here (Android branch):
/// - Qt/src/AppStorage.cpp:73-82   dataDirectory() -> AppLocalDataLocation
/// - Qt/src/AppStorage.cpp:84-93   cacheDirectory() -> CacheLocation
/// - Qt/src/AppStorage.cpp:95-104  temporaryDirectory() -> QDir::tempPath()
/// - Qt/src/AppStorage.cpp:14-57   portableRoot is the desktop green build's
///   root only; Android never sets it, so the injected values are used verbatim.
/// - Qt/src/NativeApplication.cpp:64-68 and Qt/src/PlaybackService.cpp:419-448
///   read a JSON file only when it opens AND size <= 64 MiB.
/// - Qt/src/MusicSession.cpp:269-284 saveSession(): offline returns early;
///   bytes > 64 MiB -> "会话过大，已保留原有存档" and the old file is untouched;
///   otherwise mkpath + QSaveFile (same-directory temp + atomic commit).
/// - Qt/src/PlaybackService.cpp:438-448 same size gate for the playback file.
/// - Qt/src/LocalCollections.cpp:36-42 collections are read with a 16 MiB cap.
/// - Qt/src/BridgeProcessAndroid.cpp:197-206 exactly ONE kugou-device.json for
///   both the standard and the lite edition.
///
/// Pure Dart: dart:io + dart:convert only.
library;

import 'dart:convert';
import 'dart:io';

/// Session / playback-session size gate: 64 MiB.
///
/// Qt compares with ">" on write and "<=" on read, so exactly 67108864 bytes
/// is still accepted (Qt/src/NativeApplication.cpp:66,
/// Qt/src/MusicSession.cpp:276, Qt/src/PlaybackService.cpp:429/444).
const int kSessionLimitBytes = 67108864;

/// siren collection read cap: 16 MiB
/// (Qt/src/LocalCollections.cpp:40 "file.size() > 16 * 1024 * 1024").
const int kCollectionLimitBytes = 16777216;

/// Joins [base] and [leaf] with exactly one "/" separator.
///
/// - an empty [base] yields [leaf] with its leading "/" collapsed and no
///   separator invented ("" base + "/session.json" -> "session.json");
/// - trailing "/" on [base] and leading "/" on [leaf] are collapsed, so the
///   result never contains a doubled or a missing separator;
/// - separators inside [leaf] (for example "collections/siren.json") survive.
String joinPath(String base, String leaf) {
  var normalized = base;
  while (normalized.endsWith('/')) {
    normalized = normalized.substring(0, normalized.length - 1);
  }
  var trimmedLeaf = leaf;
  while (trimmedLeaf.startsWith('/')) {
    trimmedLeaf = trimmedLeaf.substring(1);
  }
  if (normalized.isEmpty) {
    return trimmedLeaf;
  }
  if (trimmedLeaf.isEmpty) {
    return normalized;
  }
  return '$normalized/$trimmedLeaf';
}

/// Runtime directories resolved by the host wiring layer.
///
/// Mirrors the four Qt accessors above. Every value is an absolute path on the
/// real device; nothing here is derived or guessed.
class AppStoragePaths {
  const AppStoragePaths({
    required this.dataDirectory,
    required this.cacheDirectory,
    required this.temporaryDirectory,
    required this.executableDirectory,
  });

  /// Qt AppStorage::dataDirectory() (user data; never cleared).
  final String dataDirectory;

  /// Qt AppStorage::cacheDirectory() (rebuildable).
  final String cacheDirectory;

  /// Qt AppStorage::temporaryDirectory().
  final String temporaryDirectory;

  /// Qt AppStorage::executableDirectory().
  final String executableDirectory;
}

/// File-system seam so tests never touch a real data directory.
abstract class FileSystemPort {
  /// True when [path] exists (file or directory).
  Future<bool> exists(String path);

  /// File length in bytes, or -1 when [path] is missing / unreadable.
  Future<int> sizeOrNegative(String path);

  /// Full contents, or null on any failure.
  Future<List<int>?> readAll(String path);

  /// Entry paths of [directory], or an empty list on failure.
  Future<List<String>> list(String directory);

  /// Recursive directory creation. Throws when creation is impossible.
  Future<void> createDirectory(String directory);

  /// Atomic replace of [path]: a temporary file in the SAME directory is fully
  /// written, then renamed over the target. On failure the previous file must
  /// survive and the temporary file must be cleaned up.
  Future<void> writeAtomic(String path, List<int> bytes);

  /// Deletes [path]; a missing file is not an error.
  Future<void> removeFile(String path);

  /// Deletes [path] recursively; a missing path is not an error.
  Future<void> removeTree(String path);
}

/// [FileSystemPort] backed by dart:io.
class IoFileSystemPort implements FileSystemPort {
  const IoFileSystemPort();

  @override
  Future<bool> exists(String path) async {
    try {
      final type = await FileSystemEntity.type(path, followLinks: true);
      return type != FileSystemEntityType.notFound;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<int> sizeOrNegative(String path) async {
    try {
      final type = await FileSystemEntity.type(path, followLinks: true);
      if (type != FileSystemEntityType.file) {
        return -1;
      }
      return await File(path).length();
    } catch (_) {
      return -1;
    }
  }

  @override
  Future<List<int>?> readAll(String path) async {
    try {
      return await File(path).readAsBytes();
    } catch (_) {
      return null;
    }
  }

  @override
  Future<List<String>> list(String directory) async {
    try {
      final entries =
          await Directory(directory).list(followLinks: false).toList();
      final paths = entries.map((entry) => entry.path).toList();
      paths.sort();
      return paths;
    } catch (_) {
      return <String>[];
    }
  }

  @override
  Future<void> createDirectory(String directory) {
    return Directory(directory).create(recursive: true);
  }

  @override
  Future<void> writeAtomic(String path, List<int> bytes) async {
    final directory = _parentDirectory(path);
    final temp = File(
      joinPath(directory, '${_baseName(path)}.rhine-tmp-${_nextToken()}'),
    );
    RandomAccessFile? handle;
    var committed = false;
    try {
      handle = await temp.open(mode: FileMode.writeOnly);
      await handle.writeFrom(bytes);
      await handle.flush();
      await handle.close();
      handle = null;
      // Same-directory rename is the atomic commit (QSaveFile::commit).
      await temp.rename(path);
      committed = true;
    } finally {
      if (!committed) {
        if (handle != null) {
          try {
            await handle.close();
          } catch (_) {
            // ignored: the write failure itself is what matters
          }
        }
        try {
          if (await temp.exists()) {
            await temp.delete();
          }
        } catch (_) {
          // best-effort cleanup; never mask the original failure
        }
      }
    }
  }

  @override
  Future<void> removeFile(String path) async {
    try {
      await File(path).delete();
    } catch (_) {
      // missing is not an error
    }
  }

  @override
  Future<void> removeTree(String path) async {
    try {
      final type = await FileSystemEntity.type(path, followLinks: false);
      if (type == FileSystemEntityType.notFound) {
        return;
      }
      if (type == FileSystemEntityType.directory) {
        await Directory(path).delete(recursive: true);
      } else {
        await File(path).delete();
      }
    } catch (_) {
      // missing is not an error
    }
  }

  static int _tokens = 0;

  static String _nextToken() {
    _tokens += 1;
    return '${DateTime.now().microsecondsSinceEpoch}-$_tokens';
  }
}

/// Product-side storage facade.
///
/// One instance is created by the host wiring layer with the resolved
/// [AppStoragePaths] and an optional injected [FileSystemPort].
class AppStorage {
  AppStorage({required this.paths, FileSystemPort? files, this.offline = false})
      : files = files ?? const IoFileSystemPort();

  /// Injected runtime directories; used verbatim.
  final AppStoragePaths paths;

  /// Injected file-system seam (tests pass a fake).
  final FileSystemPort files;

  /// Mirrors Host::offline, but it constrains WRITES only.
  ///
  /// [writeJsonAtomic] returns false without touching disk while offline
  /// (Qt/src/MusicSession.cpp:269-272 returns before the file is opened).
  ///
  /// Reads are gated by the caller that owns the semantics, exactly as in Qt:
  /// the session read checks !offline before opening session.json
  /// (Qt/src/NativeApplication.cpp:64-66), restoreSession() returns on its
  /// first line while offline (Qt/src/PlaybackService.cpp:420-422), and the
  /// siren collections read is deliberately NOT gated
  /// (Qt/src/LocalCollections.cpp:36-42). [readCapped] therefore has no
  /// offline branch of its own.
  bool offline;

  /// <data>/session.json (Qt/src/NativeApplication.cpp:65).
  String get sessionPath => joinPath(paths.dataDirectory, 'session.json');

  /// <data>/playback-session.json (Qt/src/PlaybackService.cpp:423).
  String get playbackSessionPath =>
      joinPath(paths.dataDirectory, 'playback-session.json');

  /// <data>/account.credential (Qt/src/PlatformAndroid.cpp:13-15).
  String get credentialPath =>
      joinPath(paths.dataDirectory, 'account.credential');

  /// <data>/qq-device.json (Qt/src/BridgeProcessAndroid.cpp:204).
  String get qqDevicePath => joinPath(paths.dataDirectory, 'qq-device.json');

  /// <data>/kugou-device.json.
  ///
  /// Exactly ONE device identity file for both the standard and the lite
  /// edition; the edition only switches tokens, never the device identity
  /// (Qt/src/BridgeProcessAndroid.cpp:197-206).
  String get kugouDevicePath =>
      joinPath(paths.dataDirectory, 'kugou-device.json');

  /// <data>/collections (LocalCollections storage root,
  /// Qt/src/LocalCollections.cpp:73-85).
  String get collectionsDirectory =>
      joinPath(paths.dataDirectory, 'collections');

  /// <data>/collections/siren.json (siren is the only collection provider,
  /// Qt/src/MusicLibrary.cpp:26-30, Qt/src/LocalCollections.cpp:36-85).
  String get sirenCollectionPath =>
      joinPath(collectionsDirectory, 'siren.json');

  /// Reads [path] only when its size is at most [limitBytes].
  ///
  /// Returns null when the file is missing, unreadable, or larger than
  /// [limitBytes]; exactly [limitBytes] is readable, mirroring the Qt gate
  /// "size() <= 64 * 1024 * 1024" (Qt/src/NativeApplication.cpp:66). Nothing
  /// is ever deleted: the caller decides the fallback.
  Future<List<int>?> readCapped(String path, int limitBytes) async {
    final size = await files.sizeOrNegative(path);
    if (size < 0 || size > limitBytes) {
      return null;
    }
    final bytes = await files.readAll(path);
    if (bytes == null || bytes.length > limitBytes) {
      return null;
    }
    return bytes;
  }

  /// Writes [json] as compact UTF-8 JSON with the atomic Qt save semantics.
  ///
  /// Order of operations matters and mirrors Qt/src/MusicSession.cpp:269-284:
  /// 1. [offline] -> return false without touching anything.
  /// 2. Serialize; a serialization failure returns false (never an empty file).
  /// 3. "bytes.length > limitBytes" -> return false. The size check happens
  ///    BEFORE any create/truncate, so the old file stays byte-identical.
  /// 4. Otherwise createDirectory(parent) + writeAtomic (same-directory temp
  ///    file then atomic rename). Any failure keeps the old file.
  ///
  /// Returns true only when the commit succeeded.
  Future<bool> writeJsonAtomic(
    String path,
    Object? json, {
    int limitBytes = kSessionLimitBytes,
  }) async {
    if (offline) {
      return false;
    }
    final List<int> bytes;
    try {
      // jsonEncode emits compact output and preserves Map insertion order.
      bytes = utf8.encode(jsonEncode(json));
    } catch (_) {
      return false;
    }
    if (bytes.length > limitBytes) {
      return false;
    }
    final directory = _parentDirectory(path);
    try {
      // Qt order is QDir().mkpath(directory) then the save (MusicSession.cpp:280).
      // A relative target with no parent component has nothing to create.
      if (directory.isNotEmpty) {
        await files.createDirectory(directory);
      }
      await files.writeAtomic(path, bytes);
      return true;
    } catch (_) {
      return false;
    }
  }
}

/// Local dirname: dart:io has no path helper and pubspec declares no package:path.
String _parentDirectory(String path) {
  final index = path.lastIndexOf('/');
  if (index < 0) {
    return '';
  }
  if (index == 0) {
    return '/';
  }
  return path.substring(0, index);
}

/// Local basename, used only to name the temporary file.
String _baseName(String path) {
  final index = path.lastIndexOf('/');
  return index < 0 ? path : path.substring(index + 1);
}
