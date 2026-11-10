// T22-C18-W4-SIREN（原子 A4）——塞壬唱片曲库 part 的领域层测试。
//
// 被测文件：lib/domain/library/siren_catalog.dart
// 规范来源：Qt/src/MusicSiren.cpp
//   7-23    reloadSirenCollections
//   28-88   loadSirenCatalog
//   91-190  searchSirenLocal
//   193-246 openSirenAllSongs
//   251-335 loadSirenSource
// 上游数据形状：MusicBridge/client/siren.mjs（30 条/页；key 形状
//   'siren:song:<id>' / 'siren:album:<id>' / 'siren:artist:<a+sha1(name)[0:16]>'）
//
// 仓库本阶段禁止运行验证：本文件仅编写，**RED/GREEN 均未执行**。
// 计划执行入口：flutter test test/domain/siren_catalog_test.dart
//
// 注意：本文件是独立 library，无法访问 music_library.dart 的私有成员
// （_pendingLane / _playLiked / _pref），因此那些内部状态只通过可观测行为
// （是否发出请求、public 字段、状态文案）间接断言。

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:rhine_music_database/domain/library/music_library.dart';

// ---------------------------------------------------------------------------
// 通用工具
// ---------------------------------------------------------------------------

/// 把 unawaited 的异步链跑完（bootstrap / api 回调 / choose 等）。
Future<void> _settle() async {
  for (int i = 0; i < 12; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

/// 宿主回包：{code: 200, value: ...}，等价于 MusicApiClient 的成功分支。
HostReply _ok(Object? value) =>
    HostReply(<String, Object?>{'code': 200, 'value': value});

List<Object?> _ids(List<JsonMap> items) =>
    <Object?>[for (final JsonMap item in items) item['id']];

List<String> _likedIds(int count) =>
    <String>[for (int i = 0; i < count; i++) 'id' + i.toString()];

JsonMap _song(
  String id, {
  String title = '歌',
  String album = '',
  String artist = '塞壬唱片-MSR',
  String cover = 'cover',
  String artistId = '',
  String artistName = '',
}) {
  final String name = artistName.isEmpty ? artist : artistName;
  final String aid = artistId.isEmpty ? 'a' + id : artistId;
  return <String, Object?>{
    'kind': 'song',
    'id': id,
    'title': title,
    'artist': artist,
    'album': album,
    'albumID': '',
    'cover': cover,
    'duration': 0,
    'trackCount': 0,
    'provider': 'siren',
    'key': 'siren:song:' + id,
    'artists': <Object?>[
      <String, Object?>{'id': aid, 'name': name},
    ],
  };
}

JsonMap _album(String id, {String title = '专辑', String artist = '塞壬唱片-MSR'}) {
  return <String, Object?>{
    'kind': 'album',
    'id': id,
    'title': title,
    'artist': artist,
    'cover': 'cover',
    'trackCount': 1,
    'provider': 'siren',
    'key': 'siren:album:' + id,
  };
}

/// 本地自建歌单（lists[2]，来自 SirenCollectionsPort.playlists()）。
JsonMap _playlistItem(String id, String title) {
  return <String, Object?>{
    'kind': 'playlist',
    'id': id,
    'title': title,
    'provider': 'netease',
    'key': 'siren:playlist:' + id,
  };
}

// ---------------------------------------------------------------------------
// 端口替身（必须完整实现，不要复用 library_test.dart 里那份不完整的实现）
// ---------------------------------------------------------------------------

class _CancelableTimer implements Cancelable {
  _CancelableTimer(Duration delay, void Function() action) {
    _timer = Timer(delay, action);
  }

  late final Timer _timer;

  @override
  void cancel() {
    _timer.cancel();
  }
}

class _Prefs implements LibraryPreferencesPort {
  _Prefs([Map<String, String>? initial])
      : _values = <String, String>{...?initial};

  final Map<String, String> _values;

  @override
  String? read(String key) => _values[key];

  @override
  void write(String key, String value) {
    _values[key] = value;
  }
}

class _Host implements LibraryHostPort {
  final List<String> opened = <String>[];
  final List<String> cookies = <String>[];
  String selected = '';

  @override
  bool authenticated = true;

  @override
  bool offline = false;

  @override
  bool localEnabled = true;

  @override
  Future<void> clearCache() async {}

  @override
  Future<void> invalidateMetadata() async {}

  @override
  Future<void> openExternal(String url) async {
    opened.add(url);
  }

  @override
  String fromLink(String text) => text;

  @override
  Future<String?> loadCover(String url) async => null;

  @override
  Future<void> acceptCookies(String value, int epoch, String credentialKey) async {
    cookies.add(value);
  }

  @override
  String qr(String key) => 'qr:' + key;

  @override
  String qrImage(String data) => 'img:' + data;

  @override
  bool hasCredential(String provider) => false;

  @override
  Future<String> saveCredential() async => 'cred';

  @override
  Future<void> logout() async {}

  @override
  Future<void> setProvider(String provider) async {
    selected = provider;
  }

  @override
  Future<void> setKugouEdition(String edition) async {}

  @override
  Future<void> playOfficial(String id, void Function(String message) done) async {}

  @override
  Cancelable schedule(Duration delay, void Function() action) =>
      _CancelableTimer(delay, action);
}

typedef _Call = ({String route, JsonMap params});

class _Wire implements HostRequestPort {
  _Wire({this.handler});

  HostReply Function(String route, JsonMap params)? handler;
  final List<_Call> calls = <_Call>[];

  List<String> get routes => <String>[for (final _Call call in calls) call.route];

  void clear() => calls.clear();

  @override
  Future<HostReply> requestJson(String route, JsonMap params) async {
    calls.add((route: route, params: params));
    final HostReply Function(String route, JsonMap params)? current = handler;
    if (current == null) {
      return HostReply.failure('未配置');
    }
    return current(route, params);
  }
}

class _Collections implements SirenCollectionsPort {
  _Collections({List<String>? liked, List<JsonMap>? playlists})
      : _liked = <String>[...?liked],
        _playlists = <JsonMap>[...?playlists];

  final List<String> _liked;
  final List<JsonMap> _playlists;

  @override
  String get creatorId => 'creator-0';

  @override
  List<String> likedIds() => List<String>.of(_liked);

  @override
  bool isLiked(String id) => _liked.contains(id);

  @override
  bool setLiked(String id, bool liked) {
    if (liked) {
      if (!_liked.contains(id)) {
        _liked.add(id);
      }
    } else {
      _liked.remove(id);
    }
    return true;
  }

  @override
  List<JsonMap> playlists() => List<JsonMap>.of(_playlists);

  @override
  JsonMap playlist(String id) => <String, Object?>{};

  @override
  List<String> tracks(String id) => <String>[];

  @override
  String createPlaylist(String name) => 'new-playlist';

  @override
  bool renamePlaylist(String id, String name) => false;

  @override
  bool deletePlaylist(String id) => false;

  @override
  bool addTrack(String id, String trackId) => false;

  @override
  bool removeTrack(String id, String trackId) => false;
}

class _Env {
  _Env(this.library, this.host, this.prefs, this.wire, this.collections);

  final MusicLibrary library;
  final _Host host;
  final _Prefs prefs;
  final _Wire wire;
  final _Collections? collections;
}

/// 塞壬环境：构造后放空 _bootstrap 的 reload + catalog 两条 unawaited 请求
/// （默认 handler 返回失败），再清空调用记录，便于逐个断言。
Future<_Env> _sirenEnv({
  List<String>? liked,
  List<JsonMap>? playlists,
  Map<String, String>? prefs,
}) async {
  final _Prefs prefsPort =
      _Prefs(<String, String>{'provider': 'siren', ...?prefs});
  final _Host host = _Host();
  final _Wire wire = _Wire();
  final _Collections collections =
      _Collections(liked: liked, playlists: playlists);
  final MusicLibrary library = MusicLibrary(
    host: host,
    preferences: prefsPort,
    requests: wire,
    collections: collections,
  );
  await _settle();
  wire.clear();
  return _Env(library, host, prefsPort, wire, collections);
}

/// 非塞壬环境（netease），用于守卫分支。
Future<_Env> _plainEnv() async {
  final _Prefs prefsPort = _Prefs(<String, String>{'provider': 'netease'});
  final _Host host = _Host();
  final _Wire wire = _Wire();
  final MusicLibrary library = MusicLibrary(
    host: host,
    preferences: prefsPort,
    requests: wire,
  );
  await _settle();
  wire.clear();
  return _Env(library, host, prefsPort, wire, null);
}

/// 曲库已就绪的塞壬环境（等价于 loadSirenCatalog 已成功返回）。
Future<_Env> _readyEnv({
  List<JsonMap>? songs,
  List<JsonMap>? albums,
  List<String>? liked,
  List<JsonMap>? playlists,
}) async {
  final _Env env = await _sirenEnv(liked: liked, playlists: playlists);
  final List<JsonMap> songList = List<JsonMap>.of(songs ?? <JsonMap>[]);
  final List<JsonMap> albumList = List<JsonMap>.of(albums ?? <JsonMap>[]);
  env.library.sirenSongs = songList;
  env.library.sirenAlbums = albumList;
  env.library.lists[3] = songList;
  env.library.lists[4] = albumList;
  env.library.totals[3] = songList.length;
  env.library.totals[4] = albumList.length;
  env.library.hasMore[3] = false;
  env.library.hasMore[4] = false;
  return env;
}

void main() {
  // -------------------------------------------------------------------------
  // 1. reloadSirenCollections（Qt MusicSiren.cpp:7-23）
  // -------------------------------------------------------------------------
  group('librarySirenReloadCollections', () {
    test('塞壬：灌入喜欢列表与本地歌单，清错误并通知', () async {
      final _Env env = await _sirenEnv(
        liked: <String>['s1', 's2'],
        playlists: <JsonMap>[_playlistItem('p1', '夜曲'), _playlistItem('p2', '晨歌')],
      );
      env.library.lists[1] = <JsonMap>[_song('stale')];
      env.library.sourceErrors[1] = '旧错误';
      env.library.sourceErrors[2] = '旧错误';
      env.library.likedCursor = 7;
      final int revision = env.library.revision;

      await librarySirenReloadCollections(env.library);

      expect(env.library.likedIds, <String>['s1', 's2']);
      expect(env.library.likedCursor, 0);
      expect(env.library.lists[1], isEmpty);
      expect(env.library.totals[1], 2);
      expect(env.library.hasMore[1], isTrue);
      expect(env.library.lists[2].length, 2);
      expect(env.library.lists[2].first['key'], 'siren:playlist:p1');
      expect(env.library.totals[2], 2);
      expect(env.library.hasMore[2], isFalse);
      expect(env.library.sourceErrors[1], isEmpty);
      expect(env.library.sourceErrors[2], isEmpty);
      expect(env.library.revision, revision + 1);
    });

    test('塞壬：喜欢列表为空时 hasMore[1] 为 false', () async {
      final _Env env = await _sirenEnv();
      await librarySirenReloadCollections(env.library);
      expect(env.library.likedIds, isEmpty);
      expect(env.library.totals[1], 0);
      expect(env.library.hasMore[1], isFalse);
      expect(env.library.lists[2], isEmpty);
      expect(env.library.hasMore[2], isFalse);
    });

    test('非塞壬：完全不动状态、不通知', () async {
      final _Env env = await _plainEnv();
      env.library.sourceErrors[1] = '旧错误';
      env.library.lists[1] = <JsonMap>[_song('keep')];
      final int revision = env.library.revision;

      await librarySirenReloadCollections(env.library);

      expect(env.library.sourceErrors[1], '旧错误');
      expect(env.library.lists[1].length, 1);
      expect(env.library.lists[2], isEmpty);
      expect(env.library.revision, revision);
    });
  });

  // -------------------------------------------------------------------------
  // 2. loadSirenCatalog（Qt MusicSiren.cpp:28-88）
  // -------------------------------------------------------------------------
  group('librarySirenLoadCatalog', () {
    test('成功：回填 3/4 栏、清错误、文案带真实数量', () async {
      final _Env env = await _sirenEnv();
      env.wire.handler = (String route, JsonMap params) {
        expect(route, '/native/siren/catalog');
        return _ok(<String, Object?>{
          'songs': <Object?>[_song('s0'), _song('s1'), _song('s2')],
          'albums': <Object?>[_album('al0'), _album('al1')],
        });
      };
      final int revision = env.library.revision;

      await librarySirenLoadCatalog(env.library);

      expect(env.wire.routes, <String>['/native/siren/catalog']);
      expect(env.wire.calls.single.params['args'], <Object?>[]);
      expect(env.library.sirenSongs.length, 3);
      expect(env.library.sirenAlbums.length, 2);
      expect(env.library.lists[3], same(env.library.sirenSongs));
      expect(env.library.lists[4], same(env.library.sirenAlbums));
      expect(env.library.totals[3], 3);
      expect(env.library.totals[4], 2);
      expect(env.library.hasMore[3], isFalse);
      expect(env.library.hasMore[4], isFalse);
      expect(env.library.sourceErrors[3], isEmpty);
      expect(env.library.sourceErrors[4], isEmpty);
      expect(env.library.status, '已加载塞壬唱片曲库：3 首 / 2 张专辑');
      expect(env.library.sirenCatalogLoading, isFalse);
      expect(env.library.revision, greaterThan(revision));
    });

    test('失败：写 sourceErrors[3]/[4]、hasMore 置真、清 pending', () async {
      final _Env env = await _sirenEnv();
      env.library.pendingSirenSearch = true;
      env.wire.handler = (String route, JsonMap params) =>
          HostReply.failure('网络异常');

      await librarySirenLoadCatalog(env.library);

      expect(env.library.sourceErrors[3], '网络异常');
      expect(env.library.sourceErrors[4], '网络异常');
      expect(env.library.hasMore[3], isTrue);
      expect(env.library.hasMore[4], isTrue);
      expect(env.library.status, '塞壬唱片曲库读取失败：网络异常');
      expect(env.library.pendingSirenSearch, isFalse);
      expect(env.library.sirenCatalogLoading, isFalse);
      expect(env.library.sirenSongs, isEmpty);
    });

    test('已在读取中：直接返回，不重复请求', () async {
      final _Env env = await _sirenEnv();
      env.library.sirenCatalogLoading = true;
      env.library.status = '哨兵';

      await librarySirenLoadCatalog(env.library);

      expect(env.wire.calls, isEmpty);
      expect(env.library.status, '哨兵');
      expect(env.library.sirenCatalogLoading, isTrue);
    });

    test('曲库已就绪：只回填 3/4 栏，不再请求上游', () async {
      final _Env env = await _readyEnv(songs: <JsonMap>[_song('s0')], albums: <JsonMap>[_album('al0')]);
      env.library.lists[3] = <JsonMap>[];
      env.library.lists[4] = <JsonMap>[];
      env.library.hasMore[3] = true;
      env.library.hasMore[4] = true;

      await librarySirenLoadCatalog(env.library);

      expect(env.wire.calls, isEmpty);
      expect(env.library.lists[3].length, 1);
      expect(env.library.lists[4].length, 1);
      expect(env.library.totals[3], 1);
      expect(env.library.hasMore[3], isFalse);
      expect(env.library.hasMore[4], isFalse);
    });

    test('曲库已就绪且待重放：清 pending 并按 keyword/searchKind 重放检索', () async {
      final _Env env = await _readyEnv(songs: <JsonMap>[_song('s0', title: '雪'), _song('s1', title: '月')]);
      env.library.keyword = '雪';
      env.library.searchKind = 'song';
      env.library.pendingSirenSearch = true;

      await librarySirenLoadCatalog(env.library);

      expect(env.library.pendingSirenSearch, isFalse);
      await _settle();
      expect(_ids(env.library.lists[0]), <Object?>['s0']);
      expect(env.library.totals[0], 1);
      expect(env.library.status, '找到 1 条结果');
    });

    test('过期回包：整体丢弃，sirenCatalogLoading 不复位', () async {
      final _Env env = await _sirenEnv();
      env.wire.handler = (String route, JsonMap params) {
        env.library.accountGeneration += 1;
        return _ok(<String, Object?>{
          'songs': <Object?>[_song('s0')],
          'albums': <Object?>[],
        });
      };

      await librarySirenLoadCatalog(env.library);

      expect(env.library.sirenCatalogLoading, isTrue);
      expect(env.library.sirenSongs, isEmpty);
      expect(env.library.lists[3], isEmpty);
      expect(env.library.status, '正在读取塞壬唱片曲库…');
    });

    test('非塞壬：不发请求、不动状态', () async {
      final _Env env = await _plainEnv();
      final int revision = env.library.revision;

      await librarySirenLoadCatalog(env.library);

      expect(env.wire.calls, isEmpty);
      expect(env.library.revision, revision);
      expect(env.library.sirenCatalogLoading, isFalse);
    });
  });

  // -------------------------------------------------------------------------
  // 3. searchSirenLocal（Qt MusicSiren.cpp:91-190）
  // -------------------------------------------------------------------------
  group('librarySirenSearchLocal', () {
    test('曲库未就绪：挂起检索、触发曲库加载，完成后自动重放', () async {
      final _Env env = await _sirenEnv();
      env.library.keyword = '雪';
      env.library.searchKind = 'song';

      // 先装回调：loadSirenCatalog 在同步段里就把请求发出去，
      // 若先 await 再装回调，第一个请求只会拿到失败回包。
      env.wire.handler = (String route, JsonMap params) => _ok(<String, Object?>{
            'songs': <Object?>[_song('s0', title: '雪'), _song('s1', title: '月')],
            'albums': <Object?>[],
          });

      // 不 await：该分支在首个 await 之前就写完了挂起状态（Qt MusicSiren.cpp:95-98）。
      final Future<void> running =
          librarySirenSearchLocal(env.library, '雪', 'song', 0, false);

      expect(env.library.pendingSirenSearch, isTrue);
      expect(env.library.searchLoading, isFalse);
      expect(env.library.status, '正在读取塞壬唱片曲库…');
      expect(env.wire.routes, contains('/native/siren/catalog'));

      await running;
      await _settle();

      expect(env.library.pendingSirenSearch, isFalse);
      expect(env.library.status, '找到 1 条结果');
      expect(_ids(env.library.lists[0]), <Object?>['s0']);
      expect(env.library.totals[0], 1);
      expect(env.library.hasMore[0], isFalse);
      expect(env.library.searchCursor, 1);
    });

    test('曲库空但 3/4 栏有残留：先用残留回填再检索', () async {
      final _Env env = await _sirenEnv();
      env.library.lists[3] = <JsonMap>[_song('s0', title: '雪')];
      env.library.lists[4] = <JsonMap>[];

      await librarySirenSearchLocal(env.library, '雪', 'song', 0, false);

      expect(env.library.sirenSongs.length, 1);
      expect(_ids(env.library.lists[0]), <Object?>['s0']);
      expect(env.library.pendingSirenSearch, isFalse);
      expect(env.wire.calls, isEmpty);
    });

    test('song：30 条一页、hasMore 与 searchCursor 正确', () async {
      final _Env env = await _readyEnv(
        songs: <JsonMap>[for (int i = 0; i < 45; i++) _song('s' + i.toString(), title: '歌' + i.toString())],
      );

      await librarySirenSearchLocal(env.library, '歌', 'song', 0, false);

      expect(env.library.lists[0].length, 30);
      expect(env.library.lists[0].first['id'], 's0');
      expect(env.library.lists[0].last['id'], 's29');
      expect(env.library.totals[0], 45);
      expect(env.library.searchCursor, 30);
      expect(env.library.hasMore[0], isTrue);
      expect(env.library.offsets[0], 0);
      expect(env.library.status, '找到 45 条结果');
      expect(env.library.searchLoading, isFalse);
      expect(env.library.selectedLane, 0);
      expect(env.library.modeRequests, contains('archive'));
      expect(env.library.frame['mode'], 'archive');
      expect(env.wire.calls, isEmpty);

      await librarySirenSearchLocal(env.library, '歌', 'song', 30, true);

      expect(env.library.lists[0].length, 45);
      expect(env.library.searchCursor, 45);
      expect(env.library.hasMore[0], isFalse);
      expect(env.library.totals[0], 45);
    });

    test('song：空串全匹配，trim 且大小写不敏感', () async {
      final _Env env = await _readyEnv(
        songs: <JsonMap>[_song('s0', title: 'Moon Light'), _song('s1', title: '星')],
      );

      await librarySirenSearchLocal(env.library, '  moon  ', 'song', 0, false);
      expect(_ids(env.library.lists[0]), <Object?>['s0']);

      await librarySirenSearchLocal(env.library, '   ', 'song', 0, false);
      expect(_ids(env.library.lists[0]), <Object?>['s0', 's1']);
      expect(env.library.status, '找到 2 条结果');
    });

    test('song：title / album / artist 三处命中且保持曲库顺序', () async {
      final _Env env = await _readyEnv(
        songs: <JsonMap>[
          _song('s0', title: '甲', artist: 'A'),
          _song('s1', title: '乙', album: '月之专辑', artist: 'B'),
          _song('s2', title: '丙', artist: '月歌手'),
          _song('s3', title: '丁', artist: 'C'),
        ],
      );

      await librarySirenSearchLocal(env.library, '月', 'song', 0, false);

      expect(_ids(env.library.lists[0]), <Object?>['s1', 's2']);
      expect(env.library.totals[0], 2);
      expect(env.library.status, '找到 2 条结果');
    });

    test('start 越过总数：空页、hasMore=false、无匹配文案', () async {
      final _Env env = await _readyEnv(songs: <JsonMap>[_song('s0', title: '雪')]);

      await librarySirenSearchLocal(env.library, '雪', 'song', 5, true);

      expect(env.library.lists[0], isEmpty);
      expect(env.library.searchCursor, 5);
      expect(env.library.hasMore[0], isFalse);
      expect(env.library.totals[0], 1);
      expect(env.library.status, '没有匹配的音乐');
    });

    test('album：只匹配专辑的 title/artist', () async {
      final _Env env = await _readyEnv(
        albums: <JsonMap>[
          _album('al0', title: '月之专辑', artist: 'A'),
          _album('al1', title: '晨', artist: '月歌手'),
          _album('al2', title: '星', artist: 'C'),
        ],
      );

      await librarySirenSearchLocal(env.library, '月', 'album', 0, false);

      expect(_ids(env.library.lists[0]), <Object?>['al0', 'al1']);
      expect(env.library.status, '找到 2 条结果');

      await librarySirenSearchLocal(env.library, '不存在', 'album', 0, false);
      expect(env.library.lists[0], isEmpty);
      expect(env.library.status, '没有匹配的音乐');
    });

    test('artist：同名合并、trackCount 降序、字段取自首个命中', () async {
      final _Env env = await _readyEnv(
        songs: <JsonMap>[
          _song('s0', artistId: 'aJIA', artistName: '甲', cover: 'c0'),
          _song('s1', artistId: 'aOTHER', artistName: '甲', cover: 'c9'),
          _song('s2', artistId: 'aYI', artistName: '乙'),
        ],
      );

      await librarySirenSearchLocal(env.library, '', 'artist', 0, false);

      expect(env.library.lists[0].length, 2);
      final JsonMap first = env.library.lists[0].first;
      expect(first['kind'], 'artist');
      expect(first['id'], 'aJIA');
      expect(first['key'], 'siren:artist:aJIA');
      expect(first['title'], '甲');
      expect(first['artist'], '甲');
      expect(first['cover'], 'c0');
      expect(first['trackCount'], 2);
      expect(first['provider'], 'siren');
      expect((first['artists']! as List<Object?>).first, <String, Object?>{'id': 'aJIA', 'name': '甲'});
      final JsonMap second = env.library.lists[0].last;
      expect(second['title'], '乙');
      expect(second['trackCount'], 1);
      expect(env.library.totals[0], 2);
    });

    test('artist：trackCount 相同按 title 升序', () async {
      final _Env env = await _readyEnv(
        songs: <JsonMap>[
          _song('s0', artistId: 'aB', artistName: 'Beta'),
          _song('s1', artistId: 'aA', artistName: 'Alpha'),
        ],
      );

      await librarySirenSearchLocal(env.library, '', 'artist', 0, false);

      expect(<Object?>[for (final JsonMap item in env.library.lists[0]) item['title']], <Object?>['Alpha', 'Beta']);
    });

    test('artist：按歌手名过滤', () async {
      final _Env env = await _readyEnv(
        songs: <JsonMap>[
          _song('s0', artistId: 'aB', artistName: 'Beta'),
          _song('s1', artistId: 'aA', artistName: 'Alpha'),
        ],
      );

      await librarySirenSearchLocal(env.library, 'bet', 'artist', 0, false);

      expect(<Object?>[for (final JsonMap item in env.library.lists[0]) item['title']], <Object?>['Beta']);
    });

    test('playlist：命中本地歌单，空态文案不同', () async {
      final _Env env = await _readyEnv(
        liked: <String>[],
        playlists: <JsonMap>[_playlistItem('p1', '夜曲')],
      );

      await librarySirenSearchLocal(env.library, '夜', 'playlist', 0, false);

      expect(env.library.lists[0].length, 1);
      expect(env.library.lists[0].single['key'], 'siren:playlist:p1');
      expect(env.library.status, '找到 1 条结果');

      await librarySirenSearchLocal(env.library, '不存在', 'playlist', 0, false);

      expect(env.library.lists[0], isEmpty);
      expect(env.library.status, '没有匹配的本地歌单');
    });
  });

  // -------------------------------------------------------------------------
  // 4. openSirenAllSongs（Qt MusicSiren.cpp:193-246）
  // -------------------------------------------------------------------------
  group('libraryOpenSirenAllSongs', () {
    test('曲库未加载：返回 false 并写文案', () async {
      final _Env env = await _sirenEnv();
      final int revision = env.library.revision;

      final bool opened = await libraryOpenSirenAllSongs(env.library);

      expect(opened, isFalse);
      expect(env.library.status, '塞壬唱片曲库尚未加载');
      expect(env.library.directory, isNull);
      expect(env.library.revision, revision + 1);
    });

    test('非塞壬：返回 false 并写文案', () async {
      final _Env env = await _plainEnv();
      final bool opened = await libraryOpenSirenAllSongs(env.library);
      expect(opened, isFalse);
      expect(env.library.status, '塞壬唱片曲库尚未加载');
    });

    test('打开全部歌曲：目录条目、代数与跳转逐项对齐 Qt', () async {
      final _Env env = await _readyEnv(
        songs: <JsonMap>[_song('s1', cover: 'c1'), _song('s2', cover: 'c2')],
      );
      env.library.selectedLane = 2;
      env.library.physicalSlots[2] = <int>[5, 6];
      // Qt: frame["selected"].toInt(physicalSlots[selectedLane].value(0, -1))；
      // 未设置 selected 时回落到该栏首个物理格位。
      env.library.frame.remove('selected');
      env.library.rowMemory[3] = 1;
      env.library.current = <String, Object?>{'id': 'old'};
      env.library.tracks = <JsonMap>[_song('t0')];
      env.library.trackIds = <String>['t0'];
      env.library.coverImage = 'old-cover';
      env.library.coverKey = 'old-key';
      env.library.wantsSongDetails = true;
      env.library.directoryInfo = true;
      env.library.directoryLoading = true;
      env.library.detailLoading = true;
      final int directoryGeneration = env.library.directoryGeneration;
      final int selectionGeneration = env.library.selectionGeneration;
      final int wikiGeneration = env.library.wikiGeneration;

      final bool opened = await libraryOpenSirenAllSongs(env.library);

      expect(opened, isTrue);
      final DirectoryFolder folder = env.library.directory!;
      expect(folder.item['provider'], 'siren');
      expect(folder.item['kind'], 'playlist');
      expect(folder.item['virtual'], isTrue);
      expect(folder.item['id'], 'siren-all');
      expect(folder.item['key'], 'siren:playlist:all');
      expect(folder.item['title'], '全部歌曲');
      expect(folder.item['artist'], '塞壬唱片');
      expect(folder.item['cover'], 'c1');
      expect(folder.item['description'], '塞壬唱片全部歌曲');
      expect(folder.item['trackCount'], 2);
      expect(_ids(folder.songs), <Object?>['s1', 's2']);
      expect(folder.ids, <String>['s1', 's2']);
      expect(folder.cursor, 2);
      expect(folder.parentPhysical, 5);
      expect(folder.parentLane, 2);
      expect(folder.parentItem, <String, Object?>{'id': 'old'});
      expect(folder.parent, isNull);
      expect(folder.anchor, 25);
      expect(folder.index, 0);
      expect(env.library.selectedPhysical, -1);
      expect(env.library.directoryInfo, isFalse);
      expect(env.library.directoryLoading, isFalse);
      expect(env.library.wantsSongDetails, isFalse);
      expect(env.library.tracks, isEmpty);
      expect(env.library.trackIds, isEmpty);
      expect(env.library.coverImage, isEmpty);
      expect(env.library.coverKey, isEmpty);
      // 末尾的 choose(songs.first())（Qt MusicSiren.cpp:245）会同步把 detailLoading 置 true
      // （music_library.dart:1596 与 :1610），所以这里看到的是 true。
      expect(env.library.detailLoading, isTrue);
      expect(env.library.status, '已打开：全部歌曲');
      expect(env.library.modeRequests, contains('archive'));
      expect(env.library.navigationRequests.length, 1);
      expect(env.library.navigationRequests.single.axis, 'lane');
      expect(env.library.navigationRequests.single.direction, 1);
      expect(env.library.directoryGeneration, directoryGeneration + 1);
      expect(env.library.selectionGeneration, greaterThanOrEqualTo(selectionGeneration + 1));
      expect(env.library.wikiGeneration, greaterThanOrEqualTo(wikiGeneration + 1));

      await _settle();
      expect(env.library.current['id'], 's1');

      // songs 是副本：往目录里加歌不会污染曲库或 ids。
      folder.songs.add(_song('s3'));
      expect(env.library.lists[3].length, 2);
      expect(env.library.sirenSongs.length, 2);
      expect(folder.ids.length, 2);
    });

    test('已选中物理格位时优先使用 selectedPhysical 作为 parentPhysical', () async {
      final _Env env = await _readyEnv(songs: <JsonMap>[_song('s1')]);
      env.library.selectedLane = 1;
      env.library.physicalSlots[1] = <int>[9];
      env.library.selectedPhysical = 3;

      await libraryOpenSirenAllSongs(env.library);

      expect(env.library.directory!.parentPhysical, 3);
      expect(env.library.directory!.parentLane, 1);
      // destination = (1 + 1) % 5 = 2
      expect(env.library.directory!.anchor, 16 + env.library.rowMemory[2]);
    });
  });

  // -------------------------------------------------------------------------
  // 5. loadSirenSource（Qt MusicSiren.cpp:251-335）
  // -------------------------------------------------------------------------
  group('librarySirenLoadSource', () {
    test('lane 越界：什么都不做', () async {
      final _Env env = await _readyEnv(songs: <JsonMap>[_song('s0')]);
      env.library.status = '哨兵';
      final int revision = env.library.revision;

      await librarySirenLoadSource(env.library, 0);
      await librarySirenLoadSource(env.library, 5);

      expect(env.wire.calls, isEmpty);
      expect(env.library.status, '哨兵');
      expect(env.library.revision, revision);
    });

    test('非塞壬：什么都不做', () async {
      final _Env env = await _plainEnv();
      final int revision = env.library.revision;

      await librarySirenLoadSource(env.library, 1);

      expect(env.wire.calls, isEmpty);
      expect(env.library.revision, revision);
    });

    test('lane 2：整批灌入本地歌单并通知', () async {
      final _Env env = await _sirenEnv(
        playlists: <JsonMap>[_playlistItem('p1', '夜曲'), _playlistItem('p2', '晨歌')],
      );
      env.library.lists[2] = <JsonMap>[];
      env.library.sourceErrors[2] = '旧错误';
      env.library.hasMore[2] = true;
      final int revision = env.library.revision;

      await librarySirenLoadSource(env.library, 2);

      expect(env.library.lists[2].length, 2);
      expect(env.library.totals[2], 2);
      expect(env.library.hasMore[2], isFalse);
      expect(env.library.sourceErrors[2], isEmpty);
      expect(env.library.status, '已读取本地歌单');
      expect(env.wire.calls, isEmpty);
      expect(env.library.revision, revision + 1);
    });

    test('lane 2：无歌单时给创建提示', () async {
      final _Env env = await _sirenEnv();
      await librarySirenLoadSource(env.library, 2);
      expect(env.library.lists[2], isEmpty);
      expect(env.library.totals[2], 0);
      expect(env.library.status, '暂无本地歌单，可点击创建歌单');
    });

    test('lane 3：曲库未就绪时委派 catalog 并最终回填', () async {
      final _Env env = await _sirenEnv();
      env.wire.handler = (String route, JsonMap params) => _ok(<String, Object?>{
            'songs': <Object?>[_song('s0')],
            'albums': <Object?>[],
          });

      // 不 await：lane 3 分支同步委派 catalog（Qt MusicSiren.cpp:265-272）。
      final Future<void> running = librarySirenLoadSource(env.library, 3);

      expect(env.wire.routes, <String>['/native/siren/catalog']);
      expect(env.library.sirenCatalogLoading, isTrue);
      expect(env.library.status, '正在读取塞壬唱片曲库…');

      await running;
      await _settle();

      expect(env.library.lists[3].length, 1);
      expect(env.library.totals[3], 1);
      expect(env.library.hasMore[3], isFalse);
      expect(env.library.status, '已加载塞壬唱片曲库：1 首 / 0 张专辑');
    });

    test('lane 4：曲库就绪时只落 hasMore，不发请求也不改文案', () async {
      final _Env env = await _readyEnv(songs: <JsonMap>[_song('s0')]);
      env.library.hasMore[3] = true;
      env.library.hasMore[4] = true;
      env.library.status = '哨兵';
      final int revision = env.library.revision;

      await librarySirenLoadSource(env.library, 4);

      expect(env.wire.calls, isEmpty);
      expect(env.library.hasMore[4], isFalse);
      expect(env.library.hasMore[3], isTrue);
      expect(env.library.status, '哨兵');
      expect(env.library.revision, revision);
    });

    test('lane 1：100 条一页，两次拉满后 hasMore 落假', () async {
      final _Env env = await _readyEnv(liked: _likedIds(150));
      final List<List<Object?>> pages = <List<Object?>>[];
      env.wire.handler = (String route, JsonMap params) {
        expect(route, '/native/siren/songs');
        final List<Object?> args = params['args']! as List<Object?>;
        final List<Object?> page = args.single! as List<Object?>;
        pages.add(page);
        return _ok(<Object?>[
          for (final Object? id in page)
            _song(id! as String, title: '喜欢'),
        ]);
      };

      await librarySirenLoadSource(env.library, 1);

      expect(env.wire.routes, <String>['/native/siren/songs']);
      expect(pages.single.length, 100);
      expect(pages.single.first, 'id0');
      expect(pages.single.last, 'id99');
      expect(env.library.lists[1].length, 100);
      expect(env.library.likedCursor, 100);
      expect(env.library.totals[1], 150);
      expect(env.library.hasMore[1], isTrue);
      expect(env.library.sourceErrors[1], isEmpty);
      expect(env.library.status, '已读取喜欢的歌曲');
      expect(env.library.personalLoading, isFalse);

      env.wire.clear();
      await librarySirenLoadSource(env.library, 1);

      expect(pages.last.length, 50);
      expect(pages.last.first, 'id100');
      expect(env.library.lists[1].length, 150);
      expect(env.library.likedCursor, 150);
      expect(env.library.hasMore[1], isFalse);
      expect(env.library.totals[1], 150);

      env.wire.clear();
      await librarySirenLoadSource(env.library, 1);

      expect(env.wire.calls, isEmpty);
      expect(env.library.lists[1].length, 150);
    });

    test('lane 1：hasMore[1] 为假时直接返回', () async {
      final _Env env = await _readyEnv(liked: _likedIds(2));
      env.library.hasMore[1] = false;
      env.library.status = '哨兵';
      final int revision = env.library.revision;

      await librarySirenLoadSource(env.library, 1);

      expect(env.wire.calls, isEmpty);
      expect(env.library.status, '哨兵');
      expect(env.library.revision, revision);
    });

    test('lane 1：喜欢为空且被强制挂起时给空态文案', () async {
      // Qt :277-279 要求 hasMore[1] 为真才会走到空页分支，这里手动构造前置条件。
      final _Env env = await _sirenEnv();
      env.library.hasMore[1] = true;
      env.library.status = '哨兵';

      await librarySirenLoadSource(env.library, 1);

      expect(env.wire.calls, isEmpty);
      expect(env.library.personalLoading, isFalse);
      expect(env.library.hasMore[1], isFalse);
      expect(env.library.totals[1], 0);
      expect(env.library.status, '暂无喜欢的歌曲');
    });

    test('lane 1：cursor 越界（all 非空）时给已读取文案', () async {
      final _Env env = await _readyEnv(liked: _likedIds(2));
      env.library.hasMore[1] = true;
      env.library.likedCursor = 5;

      await librarySirenLoadSource(env.library, 1);

      expect(env.wire.calls, isEmpty);
      expect(env.library.hasMore[1], isFalse);
      expect(env.library.totals[1], 2);
      expect(env.library.status, '已读取喜欢的歌曲');
    });

    test('lane 1：重复回包按 key 去重', () async {
      final _Env env = await _readyEnv(liked: _likedIds(2));
      env.wire.handler = (String route, JsonMap params) =>
          _ok(<Object?>[_song('id0', title: '喜欢'), _song('id1', title: '喜欢')]);

      await librarySirenLoadSource(env.library, 1);

      expect(env.library.lists[1].length, 2);
      expect(env.library.likedCursor, 2);
      expect(env.library.hasMore[1], isFalse);

      env.library.likedCursor = 0;
      env.library.hasMore[1] = true;
      await librarySirenLoadSource(env.library, 1);

      expect(env.library.lists[1].length, 2);
      expect(env.library.likedCursor, 2);
      expect(env.library.hasMore[1], isFalse);
    });

    test('lane 1：失败写 sourceErrors[1] 与状态', () async {
      final _Env env = await _readyEnv(liked: _likedIds(2));
      env.wire.handler = (String route, JsonMap params) => HostReply.failure('网络异常');

      await librarySirenLoadSource(env.library, 1);

      expect(env.library.sourceErrors[1], '网络异常');
      expect(env.library.status, '网络异常');
      expect(env.library.personalLoading, isFalse);
      expect(env.library.lists[1], isEmpty);
      expect(env.library.likedCursor, 0);
    });

    test('lane 1：过期回包整体丢弃，personalLoading 不复位', () async {
      final _Env env = await _readyEnv(liked: _likedIds(2));
      env.wire.handler = (String route, JsonMap params) {
        env.library.accountGeneration += 1;
        return _ok(<Object?>[_song('id0', title: '喜欢')]);
      };

      await librarySirenLoadSource(env.library, 1);

      expect(env.library.personalLoading, isTrue);
      expect(env.library.lists[1], isEmpty);
      expect(env.library.likedCursor, 0);
      expect(env.library.sourceErrors[1], isEmpty);
    });

    test('lane 1：选中 1 栏且未打开详情时自动落位首个物理格位', () async {
      final _Env env = await _readyEnv(liked: <String>['id0']);
      env.wire.handler = (String route, JsonMap params) =>
          _ok(<Object?>[_song('id0', title: '喜欢')]);
      env.library.selectedLane = 1;
      env.library.physicalSlots[1] = <int>[7];
      env.library.frame.remove('selected');
      env.library.current = <String, Object?>{};

      await librarySirenLoadSource(env.library, 1);
      await _settle();

      expect(env.library.selectedPhysical, 7);
      expect(env.library.current['id'], 'id0');
    });

    test('lane 1 完成后：completes 时不会触发跨栏接力请求', () async {
      // Qt :327-331 的 pending 接力要求 pending != 1，而 lane 2/3/4 在 :273 之前
      // 就 return 了，m_pendingLane 只可能是 1 —— 该接力在 Qt 里恒不触发。
      final _Env env = await _readyEnv(liked: _likedIds(1));
      env.wire.handler = (String route, JsonMap params) =>
          _ok(<Object?>[_song('id0', title: '喜欢')]);

      await librarySirenLoadSource(env.library, 1);
      await _settle();

      expect(env.wire.routes, <String>['/native/siren/songs']);
    });

    test('lane 1：personalLoading 为真时请求被推迟，不重复发', () async {
      final _Env env = await _readyEnv(liked: _likedIds(2));
      env.library.personalLoading = true;

      await librarySirenLoadSource(env.library, 1);

      expect(env.wire.calls, isEmpty);
      expect(env.library.personalLoading, isTrue);
      expect(env.library.likedCursor, 0);
    });
  });

  // -------------------------------------------------------------------------
  // 6. 契约扫描（源文件形状，防止写死数量 / 违规结构）
  // -------------------------------------------------------------------------
  group('siren_catalog.dart 契约', () {
    test('part 声明、5 个顶层函数、无 extension', () {
      final File file = File('lib/domain/library/siren_catalog.dart');
      final List<String> source = file.readAsLinesSync();
      final String text = source.join('\n');

      expect(source.first.trim(), "part of 'music_library.dart';");

      const List<String> functions = <String>[
        'librarySirenReloadCollections',
        'librarySirenLoadCatalog',
        'librarySirenSearchLocal',
        'libraryOpenSirenAllSongs',
        'librarySirenLoadSource',
      ];
      for (final String name in functions) {
        expect(RegExp('Future<(void|bool)> ' + name + '[(]').hasMatch(text), isTrue,
            reason: name);
      }

      final Iterable<RegExpMatch> top =
          RegExp(r'^Future<', multiLine: true).allMatches(text);
      expect(top.length, 5);
      expect(text.contains('extension '), isFalse);
    });

    test('无写死曲库数量：933 / 303 只允许出现在注释里', () {
      final List<String> source =
          File('lib/domain/library/siren_catalog.dart').readAsLinesSync();
      final List<String> offenders = <String>[];
      for (int i = 0; i < source.length; i++) {
        final String line = source[i];
        if (!line.contains('933') && !line.contains('303')) {
          continue;
        }
        if (line.trimLeft().startsWith('//')) {
          continue;
        }
        offenders.add((i + 1).toString() + ': ' + line);
      }
      // 933 只是 Qt UI 的颜色常量（[0.973, 0.969, 0.933]），与曲库数量无关；
      // 曲库数量完全由上游 /api/songs、/api/albums 决定。
      expect(offenders, isEmpty);
    });

    test('曲库文案模板来自 totals，且只有一处', () {
      // 注释里也会出现该文案，只统计代码行。
      final String text = File('lib/domain/library/siren_catalog.dart')
          .readAsLinesSync()
          .where((String line) => !line.trimLeft().startsWith('//'))
          .join('\n');
      expect('已加载塞壬唱片曲库：'.allMatches(text).length, 1);
      expect(text.contains('lib.totals[3]'), isTrue);
      expect(text.contains('lib.totals[4]'), isTrue);
    });
  });
}
