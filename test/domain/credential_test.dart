/// T24-S04 凭据存储逐来源语义测试：逐条对齐 Qt/src/Host.cpp 与 PlatformAndroid.cpp。
///
/// 契约来源（每条断言在注释里给出 Qt 行号）：
/// - Host.cpp:541-553 hasCredential（qq=qqmusic_session、netease=MUSIC_U、
///   kugou=__kugou[edition].token 非空且 userid>0，local/siren 恒 false）。
/// - Host.cpp:599-605 saveCredential（空串=成功，非空=用户可见提示）。
/// - Host.cpp:609-662 logout 逐来源清理 + cookies 为空才删文件。
/// - Host.cpp:517-530 cookie 更新后按需持久化。
/// - PlatformAndroid.cpp:10-46 account.credential 的路径/写/权限/删除。
///
/// 任务契约禁止执行 flutter/dart test；本文件只编写、不运行，RED/GREEN 均未执行。
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:rhine_music_database/domain/account/credential_store.dart';
import 'package:rhine_music_database/domain/account/login_session.dart';

class _FakeStorage implements CredentialStorage {
  String? contents;
  int writeResult = -1;
  int writes = 0;
  int removes = 0;
  int chmods = 0;
  bool directoryCreated = true;
  String? lastPath;
  List<int> lastBytes = <int>[];

  @override
  List<int> read(String path) => contents == null ? <int>[] : utf8.encode(contents!);

  @override
  int write(String path, List<int> bytes) {
    writes++;
    lastPath = path;
    lastBytes = bytes;
    if (writeResult >= 0) {
      return writeResult;
    }
    contents = utf8.decode(bytes);
    return bytes.length;
  }

  @override
  void setOwnerReadWrite(String path) => chmods++;

  @override
  void remove(String path) {
    removes++;
    contents = null;
  }

  @override
  bool ensureDirectory(String path) => directoryCreated;
}

CredentialStore _store(_FakeStorage storage) =>
    CredentialStore(storage: storage, directory: '/data/app');

void main() {
  group('per source credential presence (Host.cpp:541-553)', () {
    test('netease reads MUSIC_U only', () {
      final _FakeStorage storage = _FakeStorage();
      final CredentialStore store = _store(storage);
      expect(store.hasCredential(AccountProvider.netease), isFalse);

      store.cookies['MUSIC_U'] = '';
      expect(store.hasCredential(AccountProvider.netease), isFalse);

      store.cookies['MUSIC_U'] = 'token';
      expect(store.hasCredential(AccountProvider.netease), isTrue);
    });

    test('qq reads qqmusic_session and ignores __qqSessions alone', () {
      final _FakeStorage storage = _FakeStorage();
      final CredentialStore store = _store(storage);
      store.cookies['__qqSessions'] = <String, Object?>{'a': 1};
      expect(store.hasCredential(AccountProvider.qq), isFalse);

      store.cookies['qqmusic_session'] = 'session';
      expect(store.hasCredential(AccountProvider.qq), isTrue);
    });

    test('kugou requires a non empty token and userid > 0 for the current edition', () {
      final _FakeStorage storage = _FakeStorage();
      final CredentialStore store = _store(storage);
      store.cookies['__kugou'] = <String, Object?>{
        'standard': <String, Object?>{'token': 't', 'userid': 0},
      };
      expect(store.hasCredential(AccountProvider.kugou), isFalse);

      store.cookies['__kugou'] = <String, Object?>{
        'standard': <String, Object?>{'token': '', 'userid': 7},
      };
      expect(store.hasCredential(AccountProvider.kugou), isFalse);

      store.cookies['__kugou'] = <String, Object?>{
        'standard': <String, Object?>{'token': 't', 'userid': '7'},
      };
      expect(store.hasCredential(AccountProvider.kugou), isTrue);

      // lite 版会话不能算 standard 已登录（Host.cpp:546 cookies[kugouEdition]）
      store.edition = KugouEdition.lite;
      expect(store.hasCredential(AccountProvider.kugou), isFalse);
      store.cookies['__kugou'] = <String, Object?>{
        'standard': <String, Object?>{'token': 't', 'userid': 7},
        'lite': <String, Object?>{'token': 't2', 'userid': 9},
      };
      expect(store.hasCredential(AccountProvider.kugou), isTrue);
    });

    test('local and siren never hold credentials (Host.cpp:543)', () {
      final _FakeStorage storage = _FakeStorage();
      final CredentialStore store = _store(storage);
      store.cookies['MUSIC_U'] = 'token';
      store.cookies['qqmusic_session'] = 'session';
      expect(store.hasCredential(AccountProvider.local), isFalse);
      expect(store.hasCredential(AccountProvider.siren), isFalse);
    });
  });

  group('credential file (Host.cpp:599-605, PlatformAndroid.cpp:10-46)', () {
    test('saveCredential writes the cookie json to account.credential and returns empty', () {
      final _FakeStorage storage = _FakeStorage();
      final CredentialStore store = _store(storage);
      store.cookies['MUSIC_U'] = 'token';

      expect(store.saveCredential(), '');
      expect(storage.lastPath, '/data/app/account.credential');
      expect(storage.writes, 1);
      expect(storage.chmods, 1);
      expect(utf8.decode(storage.lastBytes), jsonEncode(<String, Object?>{'MUSIC_U': 'token'}));
    });

    test('an unwritable directory yields the Qt note and never writes', () {
      final _FakeStorage storage = _FakeStorage()..directoryCreated = false;
      final CredentialStore store = _store(storage);
      store.cookies['MUSIC_U'] = 'token';

      expect(store.saveCredential(), CredentialStore.unwritableNote);
      expect(storage.writes, 0);
      expect(storage.chmods, 0);
    });

    test('an unopenable file yields the Qt note', () {
      final _FakeStorage storage = _FakeStorage()..writeResult = -1;
      final CredentialStore store = _store(storage);
      expect(store.saveCredential(), CredentialStore.unwritableNote);
      expect(storage.chmods, 0);
    });

    test('offline mode reports success without touching the filesystem (Host.cpp:603)', () {
      final _FakeStorage storage = _FakeStorage();
      final CredentialStore store = _store(storage)..offline = true;
      expect(store.saveCredential(), '');
      expect(storage.writes, 0);
    });

    test('deleteCredential removes the credential file', () {
      final _FakeStorage storage = _FakeStorage()..contents = '{}';
      final CredentialStore store = _store(storage);
      store.deleteCredential();
      expect(storage.removes, 1);
      expect(storage.contents, isNull);
    });

    test('load parses the persisted cookie jar and tolerates garbage (Host.cpp:513-517)', () {
      final _FakeStorage storage = _FakeStorage()
        ..contents = jsonEncode(<String, Object?>{'MUSIC_U': 'token'});
      final CredentialStore store = _store(storage);
      store.load();
      expect(store.hasCredential(AccountProvider.netease), isTrue);

      storage.contents = 'not json';
      store.load();
      expect(store.cookies, isEmpty);

      storage.contents = null;
      store.load();
      expect(store.cookies, isEmpty);
    });
  });

  group('logout per source (Host.cpp:609-662)', () {
    test('qq logout drops qqmusic_session and __qqSessions but keeps the others', () {
      final _FakeStorage storage = _FakeStorage();
      final CredentialStore store = _store(storage);
      store.cookies.addAll(<String, Object?>{
        'MUSIC_U': 'netease-token',
        'qqmusic_session': 'session',
        '__qqSessions': <String, Object?>{'a': 1},
        '__kugou': <String, Object?>{
          'standard': <String, Object?>{'token': 't', 'userid': 1},
        },
      });

      store.logoutSource(AccountProvider.qq, KugouEdition.standard);

      expect(store.cookies.containsKey('qqmusic_session'), isFalse);
      expect(store.cookies.containsKey('__qqSessions'), isFalse);
      expect(store.hasCredential(AccountProvider.netease), isTrue);
      expect(store.hasCredential(AccountProvider.kugou), isTrue);
      // cookies 仍非空 → 重写文件而不是删除（Host.cpp:657-661）
      expect(storage.removes, 0);
      expect(storage.writes, 1);
    });

    test('kugou logout removes only the current edition', () {
      final _FakeStorage storage = _FakeStorage();
      final CredentialStore store = _store(storage);
      store.cookies['__kugou'] = <String, Object?>{
        'standard': <String, Object?>{'token': 't', 'userid': 1},
        'lite': <String, Object?>{'token': 't2', 'userid': 2},
      };

      store.logoutSource(AccountProvider.kugou, KugouEdition.standard);

      final Map<String, Object?> editions = store.cookies['__kugou']! as Map<String, Object?>;
      expect(editions.containsKey('standard'), isFalse);
      expect(editions.containsKey('lite'), isTrue);
    });

    test('kugou logout drops the __kugou map when the last edition goes away', () {
      final _FakeStorage storage = _FakeStorage();
      final CredentialStore store = _store(storage);
      store.cookies['__kugou'] = <String, Object?>{
        'standard': <String, Object?>{'token': 't', 'userid': 1},
      };

      store.logoutSource(AccountProvider.kugou, KugouEdition.standard);

      expect(store.cookies.containsKey('__kugou'), isFalse);
      // 没有任何来源剩余 → 删除凭据文件
      expect(storage.removes, 1);
      expect(storage.writes, 0);
    });

    test('netease logout clears the rest but preserves other source sessions (Host.cpp:631-641)', () {
      final _FakeStorage storage = _FakeStorage();
      final CredentialStore store = _store(storage);
      store.cookies.addAll(<String, Object?>{
        'MUSIC_U': 'netease-token',
        'qqmusic_session': 'session',
        '__qqSessions': <String, Object?>{'a': 1},
        '__kugou': <String, Object?>{
          'standard': <String, Object?>{'token': 't', 'userid': 1},
        },
        'unrelated': 'x',
      });

      store.logoutSource(AccountProvider.netease, KugouEdition.standard);

      expect(store.hasCredential(AccountProvider.netease), isFalse);
      expect(store.cookies.containsKey('qqmusic_session'), isTrue);
      expect(store.cookies.containsKey('__qqSessions'), isTrue);
      expect(store.cookies.containsKey('__kugou'), isTrue);
      expect(store.cookies.containsKey('unrelated'), isFalse);
    });

    test('logging out the last source deletes the file (Host.cpp:657-660)', () {
      final _FakeStorage storage = _FakeStorage();
      final CredentialStore store = _store(storage);
      store.cookies['MUSIC_U'] = 'netease-token';

      store.logoutSource(AccountProvider.netease, KugouEdition.standard);

      expect(store.cookies, isEmpty);
      expect(storage.removes, 1);
      expect(storage.writes, 0);
    });
  });

  group('cookie refresh persistence (Host.cpp:517-530)', () {
    test('a changed cookie is persisted when any source is still authenticated', () {
      final _FakeStorage storage = _FakeStorage();
      final CredentialStore store = _store(storage);
      store.cookies['MUSIC_U'] = 'netease-token';
      storage.writes = 0;

      expect(store.setCookie('qqmusic_session', 'session'), '');
      expect(storage.writes, 1);
    });

    test('a changed cookie is not persisted while no source is authenticated', () {
      final _FakeStorage storage = _FakeStorage();
      final CredentialStore store = _store(storage);

      expect(store.setCookie('unrelated', 'x'), '');
      expect(storage.writes, 0);
    });

    test('an unchanged cookie value skips the write entirely', () {
      final _FakeStorage storage = _FakeStorage();
      final CredentialStore store = _store(storage);
      store.cookies['MUSIC_U'] = 'netease-token';

      expect(store.setCookie('MUSIC_U', 'netease-token'), '');
      expect(storage.writes, 0);
    });

    test('an unchanged jar skips the write when replaced wholesale (Host.cpp:517-530)', () {
      final _FakeStorage storage = _FakeStorage();
      final CredentialStore store = _store(storage);
      store.cookies['MUSIC_U'] = 'netease-token';

      // 内容相同即不写盘：QJsonObject 的相等与插入顺序无关。
      expect(
        store.replaceCookies(<String, Object?>{'MUSIC_U': 'netease-token'}),
        '',
      );
      expect(storage.writes, 0);
    });

    test('a changed jar is written when a source stays authenticated', () {
      final _FakeStorage storage = _FakeStorage();
      final CredentialStore store = _store(storage);
      store.cookies['MUSIC_U'] = 'netease-token';

      expect(
        store.replaceCookies(<String, Object?>{
          'MUSIC_U': 'netease-token',
          'qqmusic_session': 'session',
        }),
        '',
      );
      expect(storage.writes, 1);
      expect(utf8.decode(storage.lastBytes), contains('qqmusic_session'));
    });

    test('offline mode never writes or deletes the credential file (Host.cpp:655)', () {
      final _FakeStorage storage = _FakeStorage();
      final CredentialStore store = _store(storage)..offline = true;
      store.cookies['MUSIC_U'] = 'netease-token';

      expect(store.saveCredential(), '');
      store.logoutSource(AccountProvider.netease, KugouEdition.standard);

      expect(storage.writes, 0);
      expect(storage.removes, 0);
      expect(storage.chmods, 0);
      // 内存 jar 仍按 Qt 的逐来源清理语义变化，只是不落盘。
      expect(store.cookies, isEmpty);
    });
  });
}
