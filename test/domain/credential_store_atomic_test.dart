/// T24-S04 凭据写入完整性（"atomic"）测试：成功只在整段字节真正落盘时宣告。
///
/// 契约来源：
/// - PlatformAndroid.cpp:21-42：mkpath 失败 / open 失败 / written != bytes.size() 三种情况
///   都返回用户可见提示；只有 written == bytes.size() 才返回空串。权限设置
///   （QFile::setPermissions ReadOwner|WriteOwner，:38-41）在长度比较之前无条件执行，
///   短写也会 chmod，本实现与 Qt 一致。
/// - PlatformAndroid.cpp:44-46：删除走 QFile::remove。
///
/// 设计取舍：Qt 直接以 WriteOnly|Truncate 打开目标文件，本身不是原子替换；本实现刻意
/// 保持同一路径与同一失败语义（不引入临时文件或新路径），因此"atomic"指**不谎报成功**：
/// 短写一律返回提示（权限仍按 Qt 无条件设置）。
///
/// 任务契约禁止执行 flutter/dart test；本文件只编写、不运行，RED/GREEN 均未执行。
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:rhine_music_database/domain/account/credential_store.dart';

class _RecordingStorage implements CredentialStorage {
  final List<String> writtenPaths = <String>[];
  final List<List<int>> writtenBytes = <List<int>>[];
  final List<String> chmodded = <String>[];
  final List<String> removed = <String>[];
  final List<String> directoryChecks = <String>[];
  bool directoryOk = true;
  int? forcedWriteResult;

  @override
  List<int> read(String path) => const <int>[];

  @override
  int write(String path, List<int> bytes) {
    writtenPaths.add(path);
    writtenBytes.add(bytes);
    return forcedWriteResult ?? bytes.length;
  }

  @override
  void setOwnerReadWrite(String path) => chmodded.add(path);

  @override
  void remove(String path) => removed.add(path);

  @override
  bool ensureDirectory(String path) {
    directoryChecks.add(path);
    return directoryOk;
  }
}

CredentialStore _store(_RecordingStorage storage) =>
    CredentialStore(storage: storage, directory: '/data/app');

void main() {
  group('write completeness', () {
    test('a full write reports success and sets the owner permissions once', () {
      final _RecordingStorage storage = _RecordingStorage();
      final CredentialStore store = _store(storage);
      store.cookies['MUSIC_U'] = 'token';

      expect(store.saveCredential(), '');
      expect(storage.writtenPaths, <String>['/data/app/account.credential']);
      expect(storage.chmodded, <String>['/data/app/account.credential']);
      expect(storage.directoryChecks, <String>['/data/app']);
    });

    test('a short write must not claim success (Qt still chmods first)', () {
      final _RecordingStorage storage = _RecordingStorage();
      final CredentialStore store = _store(storage);
      store.cookies['MUSIC_U'] = 'token';
      final int full = utf8.encode(jsonEncode(store.cookies)).length;
      storage.forcedWriteResult = full - 1;

      expect(store.saveCredential(), CredentialStore.unwritableNote);
      // PlatformAndroid.cpp:38-41 在 written != bytes.size() 之前就 setPermissions，
      // 所以短写路径同样有一次 chmod；不谎报成功只体现在返回提示。
      expect(storage.chmodded, <String>['/data/app/account.credential']);
    });

    test('the size check uses utf8 bytes, not string length', () {
      final _RecordingStorage storage = _RecordingStorage();
      final CredentialStore store = _store(storage);
      store.cookies['welcome-name'] = '昵称';
      final List<int> bytes = utf8.encode(jsonEncode(store.cookies));
      final int characters = jsonEncode(store.cookies).length;
      expect(bytes.length, greaterThan(characters));

      storage.forcedWriteResult = characters;
      expect(store.saveCredential(), CredentialStore.unwritableNote);

      storage.forcedWriteResult = bytes.length;
      expect(store.saveCredential(), '');
    });

    test('an unwritable file never reaches chmod', () {
      final _RecordingStorage storage = _RecordingStorage()..forcedWriteResult = -1;
      final CredentialStore store = _store(storage);
      store.cookies['MUSIC_U'] = 'token';

      expect(store.saveCredential(), CredentialStore.unwritableNote);
      expect(storage.writtenPaths, <String>['/data/app/account.credential']);
      expect(storage.chmodded, isEmpty);
    });

    test('a missing directory aborts before any write attempt', () {
      final _RecordingStorage storage = _RecordingStorage()..directoryOk = false;
      final CredentialStore store = _store(storage);
      store.cookies['MUSIC_U'] = 'token';

      expect(store.saveCredential(), CredentialStore.unwritableNote);
      expect(storage.writtenPaths, isEmpty);
    });
  });

  group('path and delete semantics', () {
    test('the credential path is directory + /account.credential (PlatformAndroid.cpp:11)', () {
      final CredentialStore store = _store(_RecordingStorage());
      expect(store.path, '/data/app/account.credential');
      expect(CredentialStore.credentialFileName, 'account.credential');
    });

    test('deleteCredential forwards the exact path to remove', () {
      final _RecordingStorage storage = _RecordingStorage();
      _store(storage).deleteCredential();
      expect(storage.removed, <String>['/data/app/account.credential']);
    });

    test('repeated saves overwrite with the latest cookie jar', () {
      final _RecordingStorage storage = _RecordingStorage();
      final CredentialStore store = _store(storage);
      store.cookies['MUSIC_U'] = 'one';
      expect(store.saveCredential(), '');
      store.cookies['MUSIC_U'] = 'two';
      expect(store.saveCredential(), '');

      expect(storage.writtenBytes.length, 2);
      expect(utf8.decode(storage.writtenBytes.last), jsonEncode(<String, Object?>{'MUSIC_U': 'two'}));
    });
  });
}
