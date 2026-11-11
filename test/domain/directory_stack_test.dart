// Qt -> Flutter 迁移 T22：目录栈（Qt/src/MusicDirectory.cpp）领域层测试。
//
// 规范来源：Qt/src/MusicDirectory.cpp 全文、Qt/src/MusicLibrary.{h,cpp} 目录成员、
// Qt/src/MusicApi.cpp:61-100（valid/代数静默丢弃）、Qt/src/MusicData.cpp:82-184
// （unique/ordered/slice/cursor/sortOrder）、Qt/src/MusicSession.cpp:260（选中槽位
// 夹取 0..39，即 5 列 8 行 = 40 格）。
// 断言里的中文文案、100 条分页、40 格网格、route 名全部逐字取自 Qt 源码证据。
//
// 仓库本阶段禁止运行验证：本文件仅编写、未执行（RED/GREEN 均未执行）。
// 计划执行入口（待授权）：flutter test test/domain/directory_stack_test.dart
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:rhine_music_database/domain/library/music_library.dart';

// ── 假宿主 ────────────────────────────────────────────────────────────────

JsonMap _song(String id, {String title = '', String artist = '', String category = ''}) {
  return <String, Object?>{
    'kind': 'song',
    'id': id,
    'title': title.isEmpty ? ('曲' + id) : title,
    'artist': artist,
    'category': category,
    'key': 'netease:song:' + id,
  };
}

JsonMap _playlist(String id, {String title = '', String provider = 'netease'}) {
  return <String, Object?>{
    'kind': 'playlist',
    'id': id,
    'title': title.isEmpty ? ('单' + id) : title,
    'artist': '',
    'key': provider + ':playlist:' + id,
  };
}

class _Prefs implements LibraryPreferencesPort {
  _Prefs([Map<String, String>? values]) : values = values ?? <String, String>{};
  final Map<String, String> values;

  @override
  String? read(String key) => values[key];

  @override
  void write(String key, String value) => values[key] = value;
}

class _Cancelable implements Cancelable {
  @override
  void cancel() {}
}

class _Host implements LibraryHostPort {
  @override
  bool authenticated = false;

  @override
  bool offline = false;

  @override
  bool localEnabled = false;

  final List<String> opened = <String>[];

  @override
  Future<void> acceptCookies(String cookies, int epoch, String credentialKey) async {}

  @override
  Future<void> clearCache() async {}

  @override
  String fromLink(String text) => '';

  @override
  bool hasCredential(String provider) => false;

  @override
  Future<void> invalidateMetadata() async {}

  @override
  Future<String?> loadCover(String url) async => null;

  @override
  Future<void> logout() async {}

  @override
  Future<void> openExternal(String url) async {
    opened.add(url);
  }

  @override
  Future<void> playOfficial(String id, void Function(String message) done) async {}

  @override
  String qr(String key) => '';

  @override
  String qrImage(String data) => '';

  @override
  Future<String> saveCredential() async => '';

  @override
  Cancelable schedule(Duration delay, void Function() action) => _Cancelable();

  @override
  Future<void> setKugouEdition(String edition) async {}

  @override
  Future<void> setProvider(String provider) async {}
}

class _Wire implements HostRequestPort {
  final List<({String route, JsonMap params})> calls = <({String route, JsonMap params})>[];

  Future<HostReply> Function(String route, JsonMap params)? handler;

  @override
  Future<HostReply> requestJson(String route, JsonMap params) async {
    calls.add((route: route, params: params));
    final h = handler;
    if (h == null) {
      return HostReply(<String, Object?>{
        'code': 200,
        'value': <Object?>[
          <String, Object?>{'kind': 'playlist', 'id': 'x', 'title': '默认', 'key': 'netease:playlist:x'},
          <Object?>[],
          <Object?>[],
        ],
      });
    }
    return h(route, params);
  }
}

class _Playback implements PlaybackPort {
  @override
  JsonMap current = <String, Object?>{};

  @override
  String coverImage = '';

  @override
  List<JsonMap> queueItems = <JsonMap>[];

  @override
  List<String> queueIds = <String>[];

  @override
  int queueIndex = 0;

  @override
  int queueSize = 0;

  @override
  List<JsonMap> history = <JsonMap>[];

  @override
  void Function()? onChanged;

  @override
  void Function(JsonMap value)? onTrackSelected;

  final List<JsonMap> played = <JsonMap>[];

  @override
  void clearCaches() {}

  @override
  void clearHistory() => history = <JsonMap>[];

  @override
  void loadQueue(List<String> ids, List<JsonMap> items) {
    queueIds = ids;
    queueItems = items;
    queueSize = ids.length;
  }

  @override
  void play(JsonMap track, {List<JsonMap>? source}) {
    played.add(track);
    current = track;
  }

  @override
  int queueIndexOfId(String id) => queueIds.indexOf(id);

  @override
  void remove(int index) {
    if (index >= 0 && index < queueIds.length) {
      queueIds.removeAt(index);
      queueItems.removeAt(index);
      queueSize = queueIds.length;
    }
  }

  @override
  void stop() {}
}

class _Collections implements SirenCollectionsPort {
  final Map<String, List<String>> byPlaylist = <String, List<String>>{};
  final List<String> liked = <String>[];

  @override
  String get creatorId => 'siren-local';

  @override
  bool addTrack(String id, String trackId) => true;

  @override
  String createPlaylist(String name) => 'playlist-' + name;

  @override
  bool deletePlaylist(String id) => true;

  @override
  bool isLiked(String id) => liked.contains(id);

  @override
  List<String> likedIds() => liked.reversed.toList();

  @override
  JsonMap playlist(String id) => <String, Object?>{'id': id, 'title': id};

  @override
  List<JsonMap> playlists() => <JsonMap>[];

  @override
  bool removeTrack(String id, String trackId) => true;

  @override
  bool renamePlaylist(String id, String name) => true;

  @override
  bool setLiked(String id, bool value) {
    if (value) {
      liked.add(id);
    } else {
      liked.remove(id);
    }
    return true;
  }

  @override
  List<String> tracks(String id) => byPlaylist[id] ?? <String>[];
}

class _Local implements LocalMusicPort {
  final Map<String, List<JsonMap>> byCollection = <String, List<JsonMap>>{};

  @override
  bool busy = false;

  @override
  String status = '';

  @override
  void cancel() {}

  @override
  List<JsonMap> collections(String kind) => <JsonMap>[];

  @override
  bool contains(String path) => false;

  @override
  void importPaths(List<String> paths) {}

  @override
  List<JsonMap> search(String query, String kind) => <JsonMap>[];

  @override
  List<JsonMap> songs() => <JsonMap>[];

  @override
  List<JsonMap> tracks(JsonMap collection) => byCollection[itemIdOf(collection)] ?? <JsonMap>[];
}

// ── 构建 ──────────────────────────────────────────────────────────────────

JsonMap _content() {
  return <String, Object?>{
    'columns': <Object?>['搜索结果', '喜欢的歌曲', '我的歌单', '收藏歌单', '收藏专辑'],
    'records': <Object?>[
      _song('1', title: '甲', category: '搜索结果'),
      _song('2', title: '乙', category: '喜欢的歌曲'),
      _song('3', title: '丙', category: '喜欢的歌曲'),
      _song('4', title: '丁', category: '我的歌单'),
      _song('5', title: '戊', category: '收藏歌单'),
      <String, Object?>{'kind': 'album', 'id': '6', 'title': '己', 'category': '收藏专辑', 'key': 'netease:album:6'},
    ],
  };
}

HostReply _ok(Object? value) =>
    HostReply(<String, Object?>{'code': 200, 'value': value});

HostReply _detailReply(JsonMap item, List<JsonMap> songs, List<String> ids) =>
    _ok(<Object?>[item, songs, ids]);

({
  MusicLibrary library,
  _Host host,
  _Prefs prefs,
  _Wire wire,
  _Playback playback,
  _Collections? collections,
  _Local? local,
}) _build({
  String provider = 'netease',
  String uid = '',
  bool siren = false,
  bool local = false,
  bool localEnabled = true,
}) {
  final prefs = _Prefs(<String, String>{'provider': provider});
  final host = _Host();
  host.localEnabled = localEnabled;
  final wire = _Wire();
  final playback = _Playback();
  final collections = siren ? _Collections() : null;
  final localPort = local ? _Local() : null;
  final library = MusicLibrary(
    host: host,
    preferences: prefs,
    requests: wire,
    content: _content(),
    collections: collections,
    player: playback,
    local: localPort,
  );
  library.uid = uid;
  return (
    library: library,
    host: host,
    prefs: prefs,
    wire: wire,
    playback: playback,
    collections: collections,
    local: localPort,
  );
}

/// 直接构造目录节点，作为各函数的 Qt 前置状态。
DirectoryFolder _folder({
  List<JsonMap>? songs,
  List<String>? ids,
  JsonMap? item,
  int index = 0,
  int anchor = 0,
  int cursor = 0,
  String sortField = 'none',
  DirectoryFolder? parent,
  int parentPhysical = 0,
  int parentLane = 0,
  JsonMap? parentItem,
  bool albumsMore = false,
  bool albumsLoading = false,
}) {
  return DirectoryFolder(
    parent: parent,
    item: item ?? _playlist('p1', title: '歌单'),
    songs: songs ?? <JsonMap>[],
    ids: ids ?? <String>[],
    index: index,
    anchor: anchor,
    cursor: cursor,
    sortField: sortField,
    parentPhysical: parentPhysical,
    parentLane: parentLane,
    parentItem: parentItem,
    albumsMore: albumsMore,
    albumsLoading: albumsLoading,
  );
}

void main() {
  group('目录排序与 40 格网格', () {
    test('setDirectorySort 只对 playlist 与白名单字段生效（Qt Directory.cpp:33-43）', () async {
      final b = _build();
      final lib = b.library;
      final folder = _folder(songs: <JsonMap>[_song('a', title: 'bn'), _song('b', title: 'an')]);
      lib.directory = folder;
      final revision = lib.revision;

      folder.item = <String, Object?>{'kind': 'album', 'id': '6', 'key': 'netease:album:6'};
      await librarySetDirectorySort(lib, 'title');
      expect(folder.sortField, 'none');
      expect(lib.revision, revision);

      folder.item = _playlist('p1', title: '歌单');
      await librarySetDirectorySort(lib, 'duration');
      expect(folder.sortField, 'none');
      expect(lib.revision, revision);

      await librarySetDirectorySort(lib, 'title');
      expect(folder.sortField, 'title');
      expect(folder.orderedSongs().map(itemIdOf).toList(), <String>['b', 'a']);
      expect(lib.revision, revision + 1);
    });

    test('updateSongs 重排后选中项物理格位不漂移（Qt Directory.cpp:22-31）', () async {
      final b = _build();
      final lib = b.library;
      final folder = _folder(
        songs: <JsonMap>[_song('a', title: 'bn'), _song('b', title: 'an'), _song('c', title: 'cn')],
        index: 0,
        anchor: 0,
      );
      lib.directory = folder;
      expect((folder.index + folder.anchor) % 40, 0);

      await librarySetDirectorySort(lib, 'title');

      expect(folder.index, 1);
      expect(folder.anchor, 39);
      expect((folder.index + folder.anchor) % 40, 0);
      expect(folder.page, 0);
    });

    test('资料页排序同步刷新 tracks（Qt Directory.cpp:33-43）', () async {
      final b = _build();
      final lib = b.library;
      final folder = _folder(songs: <JsonMap>[_song('a', title: 'bn'), _song('b', title: 'an')]);
      lib.directory = folder;
      lib.directoryInfo = true;

      await librarySetDirectorySort(lib, 'title');

      expect(lib.tracks.map(itemIdOf).toList(), <String>['b', 'a']);
    });
  });

  group('enterDirectory', () {
    test('在线分支建立目录、父链与导航请求（Qt Directory.cpp:46-142）', () async {
      final b = _build();
      final lib = b.library;
      final container = _playlist('p9', title: '目标歌单');
      final songs = <JsonMap>[_song('s1'), _song('s2')];
      final ids = <String>['s1', 's2', 's3'];
      b.wire.handler = (route, params) async {
        expect(route, '/native/netease/detail');
        expect((params['args'] as List<Object?>).first, container);
        return _detailReply(container, songs, ids);
      };
      lib.selectedLane = 2;
      lib.rowMemory[3] = 5;

      await libraryEnterDirectory(lib, container);

      final folder = lib.directory!;
      expect(folder.item, container);
      expect(folder.parentItem, container);
      expect(folder.songs.map(itemIdOf).toList(), <String>['s1', 's2']);
      expect(folder.ids, ids);
      expect(folder.cursor, 2);
      expect(folder.albumsMore, false);
      expect(lib.details['netease:playlist:p9'], container);
      expect(lib.directoryLoading, false);
      expect(lib.status, '已打开：目标歌单');
      expect(lib.modeRequests, contains('archive'));
      expect(lib.navigationRequests.last.axis, 'lane');
      expect(lib.navigationRequests.last.direction, 1);
      expect(lib.selectedPhysical, -1);
      expect(folder.anchor, 3 * 8 + 5);
      expect(folder.index, 0);
      expect(lib.current['id'], 's1');
    });

    test('过期响应整体丢弃且不清 loading（Qt MusicApi.cpp:90-100）', () async {
      final b = _build();
      final lib = b.library;
      final container = _playlist('p9');
      final completer = Completer<HostReply>();
      b.wire.handler = (route, params) => completer.future;

      final pending = libraryEnterDirectory(lib, container);
      await Future<void>.delayed(Duration.zero);
      expect(lib.directoryLoading, true);
      final loadingStatus = lib.status;

      lib.directoryGeneration++;
      completer.complete(_detailReply(container, <JsonMap>[_song('s1')], <String>['s1']));
      await pending;

      expect(lib.directoryLoading, true);
      expect(lib.status, loadingStatus);
      expect(lib.directory!.songs, isEmpty);
    });

    test('失败写「读取失败：」并清 loading（Qt Directory.cpp:115-141）', () async {
      final b = _build();
      final lib = b.library;
      b.wire.handler = (route, params) async => const HostReply.failure('上游超时');

      await libraryEnterDirectory(lib, _playlist('p9'));

      expect(lib.status, '读取失败：上游超时');
      expect(lib.directoryLoading, false);
    });

    test('local 分支走本地曲目并不请求在线平台（Qt Directory.cpp:84-98）', () async {
      final b = _build(provider: 'local', local: true);
      final lib = b.library;
      b.local!.byCollection['p1'] = <JsonMap>[_song('l1'), _song('l2')];

      await libraryEnterDirectory(lib, _playlist('p1', title: '本地歌单'));

      final folder = lib.directory!;
      expect(folder.songs.length, 2);
      expect(folder.item['trackCount'], 2);
      expect(folder.ids, <String>['l1', 'l2']);
      expect(folder.cursor, 2);
      expect(folder.albumsMore, false);
      expect(lib.directoryLoading, false);
      expect(b.wire.calls, isEmpty);
      expect(lib.current['id'], 'l1');
    });

    test('siren 本地歌单空目录写「歌单暂无可读取曲目」（Qt Directory.cpp:99-114）', () async {
      final b = _build(provider: 'siren', siren: true);
      final lib = b.library;

      await libraryEnterDirectory(lib, <String, Object?>{
        'provider': 'siren',
        'kind': 'playlist',
        'id': 'c1',
        'title': '自建歌单',
        'localCollection': true,
        'key': 'siren:playlist:c1',
      });

      expect(lib.status, '歌单暂无可读取曲目');
      expect(lib.directoryLoading, false);
    });

    test('kind==song 只走 choose，不进目录（Qt Directory.cpp:46-50）', () async {
      final b = _build();
      final lib = b.library;

      await libraryEnterDirectory(lib, _song('s1', title: '单曲'));

      expect(lib.directory, isNull);
      expect(lib.current['id'], 's1');
    });
  });

  group('openDaily', () {
    test('发现页无歌曲只写文案并返回 false（Qt Directory.cpp:147-160）', () async {
      final b = _build();
      final lib = b.library;
      lib.discover.items = <JsonMap>[];

      expect(await libraryOpenDaily(lib), false);

      expect(lib.status, '每日推荐暂无可打开的歌曲');
      expect(lib.directory, isNull);
    });

    test('虚拟歌单字段逐字对齐 Qt 且 parentItem 取 current（Qt Directory.cpp:161-209）', () async {
      final b = _build();
      final lib = b.library;
      final previous = _song('prev', title: '上一首');
      lib.current = previous;
      lib.selectedLane = 4;
      lib.rowMemory[0] = 2;
      lib.discover.items = <JsonMap>[_song('d1'), _playlist('x'), _song('d2')];

      expect(await libraryOpenDaily(lib), true);

      final folder = lib.directory!;
      expect(folder.item['provider'], 'netease');
      expect(folder.item['kind'], 'playlist');
      expect(folder.item['virtual'], true);
      expect(folder.item['id'], 'daily');
      expect(folder.item['key'], 'netease:playlist:daily');
      expect(folder.item['title'], '每日推荐');
      expect(folder.item['artist'], lib.providerName());
      // Qt Directory.cpp:178 对 cover 做了 toString()，必须是字符串。
      expect(folder.item['cover'], isA<String>());
      expect(folder.item['description'], '来自发现音乐的每日推荐，打开后不会同步到账号歌单。');
      expect(folder.item['trackCount'], 2);
      expect(folder.songs.map(itemIdOf).toList(), <String>['d1', 'd2']);
      expect(folder.ids, <String>['d1', 'd2']);
      expect(folder.cursor, 2);
      expect(folder.parentItem, previous);
      expect(folder.parentLane, 4);
      expect(folder.anchor, 0 * 8 + 2);
      expect(folder.index, 0);
      expect(lib.selectedPhysical, -1);
      expect(lib.status, '已打开：每日推荐');
      expect(lib.modeRequests, contains('archive'));
      expect(lib.navigationRequests.last.axis, 'lane');
      expect(lib.current['id'], 'd1');
    });

    test('qq 渠道标题为「每日 30 首」（Qt Directory.cpp:180）', () async {
      final b = _build(provider: 'qq');
      final lib = b.library;
      lib.discover.items = <JsonMap>[_song('d1')];

      expect(await libraryOpenDaily(lib), true);

      expect(lib.directory!.item['title'], '每日 30 首');
      expect(lib.directory!.item['key'], 'qq:playlist:daily');
    });
  });

  group('loadArtistAlbums', () {
    test('无更多页不请求；成功后按 unique/游标/更多合并（Qt Directory.cpp:211-234）', () async {
      final b = _build();
      final lib = b.library;
      final artist = <String, Object?>{
        'kind': 'artist',
        'id': 'a1',
        'title': '歌手',
        'key': 'netease:artist:a1',
      };
      final folder = _folder(item: artist, albumsMore: false);
      lib.directory = folder;

      await libraryLoadArtistAlbums(lib);
      expect(b.wire.calls, isEmpty);

      final album = <String, Object?>{'kind': 'album', 'id': 'al1', 'title': '专辑一', 'key': 'netease:album:al1'};
      folder.albumsMore = true;
      b.wire.handler = (route, params) async {
        expect(route, '/native/netease/artistAlbums');
        expect(params['args'], <Object?>['a1', 0]);
        return _ok(<String, Object?>{'items': <Object?>[album], 'rawCount': 30, 'more': true});
      };

      await libraryLoadArtistAlbums(lib);

      expect(folder.albums.length, 1);
      expect(folder.albumCursor, 30);
      expect(folder.albumsMore, true);
      expect(folder.albumsLoading, false);
      expect(lib.status, '');
    });

    test('失败文案与过期代数不回写（Qt Directory.cpp:211-234）', () async {
      final b = _build();
      final lib = b.library;
      final folder = _folder(
        item: <String, Object?>{'kind': 'artist', 'id': 'a1', 'title': '歌手', 'key': 'netease:artist:a1'},
        albumsMore: true,
      );
      lib.directory = folder;

      b.wire.handler = (route, params) async => const HostReply.failure('专辑接口失败');
      await libraryLoadArtistAlbums(lib);
      expect(lib.status, '专辑读取失败：专辑接口失败');
      expect(folder.albumsLoading, false);
    });

    test('目录代数变化后专辑响应不回写', () async {
      final b = _build();
      final lib = b.library;
      final folder = _folder(
        item: <String, Object?>{'kind': 'artist', 'id': 'a1', 'title': '歌手', 'key': 'netease:artist:a1'},
        albumsMore: true,
      );
      lib.directory = folder;
      final completer = Completer<HostReply>();
      b.wire.handler = (route, params) => completer.future;

      final pending = libraryLoadArtistAlbums(lib);
      await Future<void>.delayed(Duration.zero);
      expect(folder.albumsLoading, true);

      lib.directoryGeneration++;
      completer.complete(_ok(<String, Object?>{
        'items': <Object?>[<String, Object?>{'kind': 'album', 'id': 'al1', 'key': 'netease:album:al1'}],
        'rawCount': 30,
        'more': false,
      }));
      await pending;

      expect(folder.albums, isEmpty);
      expect(folder.albumCursor, 0);
      expect(folder.albumsLoading, true);
    });
  });

  group('openSongArtist', () {
    test('在线要求 ID 匹配 ^[a-zA-Z0-9_-]{1,80}$（Qt Directory.cpp:236-253）', () async {
      final b = _build();
      final lib = b.library;
      lib.current = <String, Object?>{
        'artists': <Object?>[
          <String, Object?>{'id': 'bad id', 'name': '坏 ID'},
        ],
      };

      await libraryOpenSongArtist(lib, 0);
      expect(lib.directory, isNull);

      lib.current = <String, Object?>{
        'artists': <Object?>[
          <String, Object?>{'id': 'a-1', 'name': '好 ID'},
        ],
      };
      b.wire.handler = (route, params) async {
        expect(route, '/native/netease/detail');
        final JsonMap requested = (params['args'] as List<Object?>).first as JsonMap;
        return _detailReply(requested, <JsonMap>[], <String>[]);
      };

      await libraryOpenSongArtist(lib, 0);

      final folder = lib.directory!;
      expect(folder.item['kind'], 'artist');
      expect(folder.item['id'], 'a-1');
      expect(folder.item['title'], '好 ID');
      expect(folder.item['key'], 'netease:artist:a-1');
    });

    test('local 分支不校验 ID 且用 local:artist: 前缀（Qt Directory.cpp:238-245）', () async {
      final b = _build(provider: 'local', local: true);
      final lib = b.library;

      lib.current = <String, Object?>{
        'artists': <Object?>[
          <String, Object?>{'id': 'loc1', 'name': '本地歌手'},
        ],
      };
      await libraryOpenSongArtist(lib, 0);
      expect(lib.directory!.item['key'], 'local:artist:loc1');
      expect(lib.directory!.item['provider'], 'local');
      expect(lib.directory!.item['kind'], 'artist');

      lib.directory = null;
      lib.current = <String, Object?>{'artists': <Object?>[]};
      await libraryOpenSongArtist(lib, 3);
      expect(lib.directory!.item['key'], 'local:artist:');
    });
  });

  _groupsRest();
}

/// 目录导航/分页/监听/进出栈/跟随播放的 Qt 断言组。
/// Qt MusicDirectory.cpp:255-503 与 MusicLibrary.h:126-130 逐条对照。
void _groupsRest() {
  group('selectDirectory', () {
    test('物理槽位由 (index+anchor)%40 决定并同步发射导航（Qt Directory.cpp:302-319）', () async {
      final b = _build();
      final lib = b.library;
      final folder = _folder(songs: <JsonMap>[_song('s1'), _song('s2'), _song('s3')], anchor: 9);
      lib.directory = folder;
      lib.directoryInfo = true;

      await librarySelectDirectory(lib, 0, 'archive');

      expect(folder.index, 0);
      expect(folder.page, 0);
      expect(lib.selectedLane, 1);
      expect(lib.selectedPhysical, 2);
      expect(lib.selectionRequests.last.index, 2);
      expect(lib.selectionRequests.last.navigation, <String, Object?>{'axis': 'row', 'direction': 1});
      expect(lib.directoryInfo, false);
      expect(lib.modeRequests.last, 'archive');
      expect(lib.current['id'], 's1');
    });

    test('QVector::value 越界返回 -1（Qt Directory.cpp:315）', () async {
      final b = _build();
      final lib = b.library;
      final folder = _folder(songs: <JsonMap>[_song('s1')], anchor: 3);
      lib.directory = folder;

      await librarySelectDirectory(lib, 0, 'archive');

      expect(lib.selectedLane, 0);
      expect(lib.selectedPhysical, -1);
      expect(lib.selectionRequests.last.index, -1);
    });

    test('axis 为空不发导航；mode=detail 透传 showDetails（Qt Directory.cpp:313-318）', () async {
      final b = _build();
      final lib = b.library;
      final folder = _folder(songs: <JsonMap>[_song('s1')], anchor: 0);
      lib.directory = folder;

      await librarySelectDirectory(lib, 0, 'detail', axis: '', direction: -3);

      expect(lib.selectionRequests.last.navigation, isEmpty);
      expect(lib.modeRequests.last, 'detail');
      expect(lib.wantsSongDetails, true);
    });

    test('越界下标不改任何状态（Qt Directory.cpp:304）', () async {
      final b = _build();
      final lib = b.library;
      final folder = _folder(songs: <JsonMap>[_song('s1')], anchor: 0);
      lib.directory = folder;
      lib.selectedPhysical = 7;
      final revision = lib.revision;

      await librarySelectDirectory(lib, 9, 'archive');
      await librarySelectDirectory(lib, -1, 'archive');

      expect(lib.selectedPhysical, 7);
      expect(lib.selectionRequests, isEmpty);
      expect(lib.revision, revision);
    });
  });

  group('navigateDirectory', () {
    test('axis=row 时 direction 取 step 原值（Qt Directory.cpp:331-333）', () async {
      final b = _build();
      final lib = b.library;
      final folder = _folder(songs: <JsonMap>[_song('s1'), _song('s2'), _song('s3')], anchor: 0);
      lib.directory = folder;

      await libraryNavigateDirectory(lib, -2, 'row');

      expect(folder.index, 1);
      expect(lib.selectionRequests.last.navigation, <String, Object?>{'axis': 'row', 'direction': -2});
    });

    test('axis 为空按 |step| 归一化为 row/lane（Qt Directory.cpp:335-337）', () async {
      final b = _build();
      final lib = b.library;
      final folder = _folder(songs: <JsonMap>[_song('s1'), _song('s2'), _song('s3')], anchor: 0);
      lib.directory = folder;

      await libraryNavigateDirectory(lib, 1, '');
      expect(lib.selectionRequests.last.navigation, <String, Object?>{'axis': 'row', 'direction': 1});

      await libraryNavigateDirectory(lib, 2, '');
      expect(lib.selectionRequests.last.navigation, <String, Object?>{'axis': 'lane', 'direction': 1});

      await libraryNavigateDirectory(lib, -3, '');
      expect(lib.selectionRequests.last.navigation, <String, Object?>{'axis': 'lane', 'direction': -1});
    });

    test('越界且仍有未消费 id 时先补页（Qt Directory.cpp:325-328）', () async {
      final b = _build();
      final lib = b.library;
      final folder = _folder(
        songs: <JsonMap>[_song('s1'), _song('s2')],
        ids: <String>['s1', 's2', 's3', 's4'],
        index: 1,
        anchor: 0,
      );
      lib.directory = folder;
      b.wire.handler = (route, params) async =>
          _ok(<Object?>[_song('s3'), _song('s4')]);

      await libraryNavigateDirectory(lib, 1, 'row');

      expect(b.wire.calls.single.route, '/native/netease/songs');
      expect((b.wire.calls.single.params['args'] as List<Object?>).first, <Object?>['s1', 's2', 's3', 's4']);
      expect(folder.songs.length, 4);
      expect(folder.cursor, 4);
      expect(folder.index, 2);
      expect(lib.directoryLoading, false);
    });

    test('空目录不做任何事（Qt Directory.cpp:323）', () async {
      final b = _build();
      final lib = b.library;
      final folder = _folder(songs: <JsonMap>[], ids: <String>['s1']);
      lib.directory = folder;

      await libraryNavigateDirectory(lib, 1, '');

      expect(b.wire.calls, isEmpty);
      expect(lib.selectionRequests, isEmpty);
    });
  });

  group('loadDirectoryPage', () {
    test('每页 100 条、游标推进、selectAfter 落在新页内（Qt Directory.cpp:343-377）', () async {
      final b = _build();
      final lib = b.library;
      final ids = List<String>.generate(120, (int i) => 'x' + i.toString());
      final folder = _folder(
        songs: <JsonMap>[_song('s1'), _song('s2')],
        ids: <String>['s1', 's2', ...ids],
        index: 1,
        anchor: 0,
      );
      lib.directory = folder;
      b.wire.handler = (route, params) async {
        final List<Object?> page = params['args'] as List<Object?>;
        final List<Object?> requestIds = page.first as List<Object?>;
        return _ok(requestIds.map((Object? id) => _song(textOf(id))).toList());
      };

      await libraryLoadDirectoryPage(lib, 10);

      expect(b.wire.calls.length, 1);
      expect(((b.wire.calls.single.params['args'] as List<Object?>).first as List<Object?>).length, 100);
      // unique 按 key 去重：第二页里回带的 s1/s2 不重复计入。
      expect(folder.songs.length, 100);
      expect(folder.cursor, 100);
      expect(folder.index, 10);
      expect(lib.directoryLoading, false);
    });

    test('数字原始 id 与同值字符串 id 命中同一条曲目（DEDUP-14）', () async {
      // Qt/src/MusicData.cpp:98-114：ordered 以 ["id"].toString() 建表，ids 来自
      // MusicDirectory::ids（原样 QJsonArray，可含数字）。修复前
      // directory_stack.dart:470 把 List<Object?> 传给 List<String> 形参
      // （argument_type_not_assignable）；本用例同时是编译闸门与语义回归。
      final b = _build();
      final lib = b.library;
      final folder = DirectoryFolder(
        item: _playlist('p1', title: '歌单'),
        ids: <Object?>[7, '8'],
      );
      lib.directory = folder;
      b.wire.handler = (route, params) async {
        final List<Object?> requestIds =
            (params['args'] as List<Object?>).first as List<Object?>;
        return _ok(requestIds.map((Object? id) => _song(identifierOf(id))).toList());
      };

      await libraryLoadDirectoryPage(lib);

      expect(folder.songs.map(itemIdOf).toList(), <String>['7', '8']);
      expect(folder.cursor, 2);
      // 请求仍带原始类型：数字 7 不得在调用点被字符串投影后发出。
      final List<Object?> sent =
          (b.wire.calls.single.params['args'] as List<Object?>).first as List<Object?>;
      expect(sent, <Object?>[7, '8']);
    });

    test('selectAfter 超过本页时递归补多页（Qt Directory.cpp:366-372）', () async {
      final b = _build();
      final lib = b.library;
      final List<String> rest = List<String>.generate(200, (int i) => 'y' + i.toString());
      final folder = _folder(
        songs: <JsonMap>[_song('s1'), _song('s2')],
        ids: <String>['s1', 's2', ...rest],
        index: 1,
        anchor: 0,
      );
      lib.directory = folder;
      b.wire.handler = (route, params) async {
        final List<Object?> requestIds =
            (params['args'] as List<Object?>).first as List<Object?>;
        return _ok(requestIds.map((Object? id) => _song(textOf(id))).toList());
      };

      await libraryLoadDirectoryPage(lib, 151);

      expect(b.wire.calls.length, 2);
      expect(folder.songs.length, 200);
      expect(folder.cursor, 200);
      expect(folder.index, 151);
      expect(folder.page, 120);
    });

    test('失败写 error 文案并清 loading（Qt Directory.cpp:356-360）', () async {
      final b = _build();
      final lib = b.library;
      final folder = _folder(songs: <JsonMap>[_song('s1')], ids: <String>['s1', 's2']);
      lib.directory = folder;
      b.wire.handler = (route, params) async => const HostReply.failure('分页失败');

      await libraryLoadDirectoryPage(lib);

      expect(lib.status, '分页失败');
      expect(lib.directoryLoading, false);
      expect(folder.songs.length, 1);
      expect(folder.cursor, 0);
    });

    test('过期分页响应不覆盖也不清 loading（Qt MusicApi.cpp:90-100）', () async {
      final b = _build();
      final lib = b.library;
      final folder = _folder(songs: <JsonMap>[_song('s1')], ids: <String>['s1', 's2']);
      lib.directory = folder;
      final completer = Completer<HostReply>();
      b.wire.handler = (route, params) => completer.future;

      final before = lib.status;
      final pending = libraryLoadDirectoryPage(lib);
      await Future<void>.delayed(Duration.zero);
      expect(folder.cursor, 0);

      lib.directoryGeneration++;
      completer.complete(_ok(<Object?>[_song('s2')]));
      await pending;

      expect(lib.directoryLoading, true);
      expect(folder.cursor, 0);
      expect(folder.songs.length, 1);
      expect(lib.status, before);
    });

    test('loading 中或游标耗尽直接返回（Qt Directory.cpp:345）', () async {
      final b = _build();
      final lib = b.library;
      final folder = _folder(songs: <JsonMap>[_song('s1')], ids: <String>['s1', 's2'], cursor: 2);
      lib.directory = folder;

      await libraryLoadDirectoryPage(lib);
      expect(b.wire.calls, isEmpty);

      folder.cursor = 0;
      lib.directoryLoading = true;
      await libraryLoadDirectoryPage(lib);
      expect(b.wire.calls, isEmpty);
    });
  });

  group('observeDirectory', () {
    test('空目录只记锚点不改选中曲目（Qt Directory.cpp:265-270）', () async {
      final b = _build();
      final lib = b.library;
      final folder = _folder(songs: <JsonMap>[], ids: <String>['s1']);
      lib.directory = folder;
      lib.current = _song('keep');

      await libraryObserveDirectory(lib, 5);

      expect(lib.selectedPhysical, 5);
      expect(lib.selectedLane, 4);
      expect(folder.anchor, 4 * 8 + 0);
      expect(lib.current['id'], 'keep');
      expect(b.wire.calls, isEmpty);
    });

    test('同格/资料页/非法格位直接返回（Qt Directory.cpp:257-264）', () async {
      final b = _build();
      final lib = b.library;
      final folder = _folder(songs: <JsonMap>[_song('s1'), _song('s2'), _song('s3')]);
      lib.directory = folder;

      lib.selectedPhysical = 5;
      await libraryObserveDirectory(lib, 5);
      expect(folder.index, 0);

      lib.selectedPhysical = -1;
      lib.directoryInfo = true;
      await libraryObserveDirectory(lib, 5);
      expect(folder.index, 0);

      lib.directoryInfo = false;
      await libraryObserveDirectory(lib, 39);
      expect(folder.index, 0);
      expect(lib.selectedPhysical, -1);
    });

    test('同栏 movement 为 0 时返回（Qt Directory.cpp:276-279）', () async {
      final b = _build();
      final lib = b.library;
      final folder = _folder(songs: <JsonMap>[_song('s1'), _song('s2'), _song('s3')], anchor: 0);
      lib.directory = folder;

      await libraryObserveDirectory(lib, 0);

      expect(lib.selectedPhysical, -1);
      expect(folder.index, 0);
      expect(folder.anchor, 0);
    });

    test('同栏移动按 (row-prevCell%8+12)%8-4 折算（Qt Directory.cpp:273-276）', () async {
      final b = _build();
      final lib = b.library;
      final folder = _folder(songs: <JsonMap>[_song('s1'), _song('s2'), _song('s3')], anchor: 9);
      lib.directory = folder;

      await libraryObserveDirectory(lib, 1);

      expect(lib.selectedLane, 1);
      expect(lib.selectedPhysical, 1);
      expect(folder.index, 2);
      expect(folder.anchor, 6);
      expect(lib.current['id'], 's3');
    });

    test('跨栏移动按 (lane*8+row-prevCell+60)%40-20 折算（Qt Directory.cpp:275）', () async {
      final b = _build();
      final lib = b.library;
      final folder = _folder(songs: <JsonMap>[_song('s1'), _song('s2'), _song('s3')], anchor: 0);
      lib.directory = folder;

      await libraryObserveDirectory(lib, 5);

      expect(lib.selectedLane, 4);
      expect(lib.selectedPhysical, 5);
      expect(folder.index, 1);
      expect(folder.anchor, 31);
      expect(lib.current['id'], 's2');
    });

    test('目标越过现有页且仍有 id 时走 loadDirectoryPage（Qt Directory.cpp:292-296）', () async {
      final b = _build();
      final lib = b.library;
      final folder = _folder(
        songs: <JsonMap>[_song('s1'), _song('s2'), _song('s3')],
        ids: <String>['s1', 's2', 's3', 'x1', 'x2', 'x3'],
        anchor: 30,
      );
      lib.directory = folder;
      b.wire.handler = (route, params) async {
        final List<Object?> requestIds =
            (params['args'] as List<Object?>).first as List<Object?>;
        return _ok(requestIds.map((Object? id) => _song(textOf(id))).toList());
      };

      await libraryObserveDirectory(lib, 0);

      expect(b.wire.calls.single.route, '/native/netease/songs');
      expect(folder.songs.length, 6);
      expect(folder.cursor, 6);
      expect(folder.index, 4);
      expect(lib.selectionRequests.last.index, -1);
      expect(lib.selectedLane, 4);
    });
  });

  group('showDirectoryInfo', () {
    test('资料页接管 current/tracks 并单独发身份请求（Qt Directory.cpp:379-398）', () async {
      final b = _build();
      final lib = b.library;
      final item = _playlist('p9', title: '歌单');
      final folder = _folder(
        songs: <JsonMap>[_song('s1'), _song('s2'), _song('s3')],
        ids: <String>['s1', 's2', 's3'],
        item: item,
        index: 1,
      );
      lib.directory = folder;
      lib.current = _song('old');
      lib.coverImage = 'cover';
      lib.coverKey = 'coverKey';
      lib.detailLoading = true;
      final selection = lib.selectionGeneration;
      final revision = lib.revision;

      await libraryShowDirectoryInfo(lib);

      expect(lib.selectionGeneration, selection + 1);
      expect(lib.directoryInfo, true);
      expect(lib.current, same(item));
      expect(lib.tracks.map(itemIdOf).toList(), <String>['s1', 's2', 's3']);
      expect(lib.trackIds, <String>['s1', 's2', 's3']);
      expect(lib.coverImage, '');
      expect(lib.coverKey, '');
      expect(lib.detailLoading, false);
      expect(lib.identityRequests.last, 'netease:playlist:p9');
      expect(lib.modeRequests.last, 'detail');
      expect(lib.revision, revision + 1);
    });

    test('无目录时不做任何事（Qt Directory.cpp:381）', () async {
      final b = _build();
      final lib = b.library;
      final revision = lib.revision;

      await libraryShowDirectoryInfo(lib);

      expect(lib.directoryInfo, false);
      expect(lib.revision, revision);
    });
  });

  group('returnToDirectory', () {
    test('目录为空时直接退栈（Qt Directory.cpp:403-406）', () async {
      final b = _build();
      final lib = b.library;
      final folder = _folder(songs: <JsonMap>[], parentLane: 2, parentPhysical: 3);
      lib.directory = folder;

      await libraryReturnToDirectory(lib);

      expect(lib.directory, isNull);
      expect(lib.selectedLane, 2);
      expect(lib.selectedPhysical, 3);
      expect(lib.status, '已返回：我的歌单');
    });

    test('资料页回到原选中项（Qt Directory.cpp:407-409）', () async {
      final b = _build();
      final lib = b.library;
      final folder = _folder(
        songs: <JsonMap>[_song('s1'), _song('s2'), _song('s3')],
        index: 2,
        anchor: 0,
      );
      lib.directory = folder;
      lib.directoryInfo = true;

      await libraryReturnToDirectory(lib);

      expect(lib.directoryInfo, false);
      expect(folder.index, 2);
      expect(lib.modeRequests.last, 'archive');
      expect(lib.selectionRequests.length, 1);
      expect(lib.current['id'], 's3');
    });

    test('普通目录只收起详情（Qt Directory.cpp:410-413）', () async {
      final b = _build();
      final lib = b.library;
      final folder = _folder(songs: <JsonMap>[_song('s1')]);
      lib.directory = folder;
      lib.wantsSongDetails = true;
      final revision = lib.revision;

      await libraryReturnToDirectory(lib);

      expect(lib.wantsSongDetails, false);
      expect(lib.modeRequests.last, 'archive');
      expect(lib.selectionRequests, isEmpty);
      expect(lib.directory, same(folder));
      expect(lib.revision, revision + 1);
    });
  });

  group('leaveDirectory', () {
    test('restore=true 沿父链回填并选中父目录（Qt Directory.cpp:417-452）', () async {
      final b = _build();
      final lib = b.library;
      final parent = _folder(
        songs: <JsonMap>[_song('p1'), _song('p2'), _song('p3')],
        ids: <String>['p1', 'p2', 'p3'],
        item: _playlist('pp', title: '父歌单'),
        index: 2,
        anchor: 0,
      );
      final folder = _folder(
        songs: <JsonMap>[_song('c1')],
        item: _playlist('cc', title: '子歌单'),
        parent: parent,
        parentLane: 3,
        parentPhysical: 4,
        parentItem: _song('p0'),
      );
      lib.directory = folder;
      lib.details['netease:playlist:cc'] = _playlist('cc', title: '缓存副本');
      final directory = lib.directoryGeneration;
      final selection = lib.selectionGeneration;
      final wiki = lib.wikiGeneration;

      await libraryLeaveDirectory(lib);

      expect(lib.directory, same(parent));
      expect(lib.directoryGeneration, directory + 1);
      expect(lib.directoryLoading, false);
      expect(lib.directoryInfo, false);
      expect(lib.selectionGeneration, selection + 1);
      expect(lib.wikiGeneration, wiki + 1);
      expect(lib.tracks, isEmpty);
      expect(lib.trackIds, isEmpty);
      expect(lib.coverImage, '');
      expect(lib.coverKey, '');
      expect(lib.detailLoading, false);
      expect(lib.status, '已返回：父歌单');
      expect(lib.selectionRequests.first.index, 4);
      expect(
        lib.selectionRequests.first.navigation,
        <String, Object?>{'axis': 'lane', 'direction': -1},
      );
      expect(lib.modeRequests, contains('archive'));
      expect(lib.current['id'], 'p3');
    });

    test('restore=true 且无父目录时用 details 回填 current（Qt Directory.cpp:435-448）', () async {
      final b = _build();
      final lib = b.library;
      final folder = _folder(
        songs: <JsonMap>[_song('c1')],
        item: _playlist('cc', title: '子歌单'),
        parentLane: 4,
        parentPhysical: 5,
      );
      lib.directory = folder;
      final cached = _playlist('cc', title: '缓存副本');
      lib.details['netease:playlist:cc'] = cached;

      await libraryLeaveDirectory(lib);

      expect(lib.directory, isNull);
      expect(lib.selectedLane, 4);
      expect(lib.selectedPhysical, 5);
      expect(lib.current, same(cached));
      expect(lib.identityRequests.last, 'netease:playlist:cc');
      expect(lib.status, '已返回：收藏专辑');
    });

    test('details 缺失时退回 parentItem（Qt Directory.cpp:435）', () async {
      final b = _build();
      final lib = b.library;
      final fallback = _song('p0', title: '父项');
      final folder = _folder(
        songs: <JsonMap>[_song('c1')],
        item: _playlist('cc', title: '子歌单'),
        parentItem: fallback,
      );
      lib.directory = folder;

      await libraryLeaveDirectory(lib);

      expect(lib.current, same(fallback));
      expect(lib.identityRequests.last, 'netease:song:p0');
    });

    test('restore=false 直接清空目录并用栏名收尾（Qt Directory.cpp:417-452）', () async {
      final b = _build();
      final lib = b.library;
      final parent = _folder(songs: <JsonMap>[_song('p1')], item: _playlist('pp', title: '父歌单'));
      final folder = _folder(
        songs: <JsonMap>[_song('c1')],
        item: _playlist('cc', title: '子歌单'),
        parent: parent,
      );
      lib.directory = folder;
      lib.selectedLane = 1;

      await libraryLeaveDirectory(lib, restore: false);

      expect(lib.directory, isNull);
      expect(lib.selectedLane, 1);
      expect(lib.selectionRequests, isEmpty);
      expect(lib.status, '已返回：喜欢的歌曲');
    });

    test('无目录时不改变代数（Qt Directory.cpp:419）', () async {
      final b = _build();
      final lib = b.library;
      final directory = lib.directoryGeneration;

      await libraryLeaveDirectory(lib);

      expect(lib.directoryGeneration, directory);
    });
  });

  group('followPlayback', () {
    test('同 key+id 直接返回（Qt Directory.cpp:457-459）', () async {
      final b = _build();
      final lib = b.library;
      final track = _song('q1');
      lib.current = track;

      await libraryFollowPlayback(lib, track);

      expect(b.wire.calls, isEmpty);
      expect(lib.selectionRequests, isEmpty);
    });

    test('队列外曲目新建「播放队列」目录并按格位选中（Qt Directory.cpp:461-503）', () async {
      final b = _build();
      final lib = b.library;
      b.playback.loadQueue(
        <String>['q1', 'q2'],
        <JsonMap>[_song('q1'), _song('q2')],
      );
      final previous = _song('prev', title: '上一首');
      lib.current = previous;
      lib.selectedLane = 2;
      lib.selectedPhysical = 3;
      lib.frame['mode'] = 'archive';

      await libraryFollowPlayback(lib, _song('q2'));

      final folder = lib.directory!;
      expect(folder.item, <String, Object?>{
        'kind': 'playlist',
        'key': 'playback:queue',
        'id': '',
        'title': '播放队列',
        'trackCount': 2,
      });
      expect(folder.songs.map(itemIdOf).toList(), <String>['q1', 'q2']);
      expect(folder.ids, <String>['q1', 'q2']);
      expect(folder.cursor, 2);
      expect(folder.index, 1);
      expect(folder.anchor, 2 * 8 + 0);
      expect(folder.parentItem, same(previous));
      expect(folder.parentPhysical, 3);
      expect(folder.parentLane, 2);
      expect(lib.selectedLane, 2);
      expect(lib.selectedPhysical, -1);
      expect(lib.selectionRequests.last.navigation, isEmpty);
      expect(lib.modeRequests.last, 'detail');
      expect(lib.frame['mode'], 'detail');
      expect(lib.current['id'], 'q2');
    });

    test('队列中找不到该曲目时只建目录不选中（Qt Directory.cpp:478-481）', () async {
      final b = _build();
      final lib = b.library;
      b.playback.loadQueue(<String>['q1', 'q2'], <JsonMap>[_song('q1'), _song('q2')]);
      final previous = _song('prev');
      lib.current = previous;

      await libraryFollowPlayback(lib, _song('q9'));

      expect(lib.directory!.index, -1);
      expect(lib.selectionRequests, isEmpty);
      expect(lib.frame['mode'], 'archive');
      expect(lib.current, same(previous));
    });
  });

  group('目录路由白名单', () {
    test('目录流程只使用 Qt 既有路由与文案（Qt MusicApi.cpp:61-70）', () async {
      final b = _build();
      final lib = b.library;
      final container = _playlist('p9', title: '目标歌单');
      b.wire.handler = (route, params) async {
        if (route == '/native/netease/detail') {
          return _detailReply(container, <JsonMap>[_song('s1'), _song('s2')], <String>['s1', 's2', 's3']);
        }
        final List<Object?> requestIds =
            (params['args'] as List<Object?>).first as List<Object?>;
        return _ok(requestIds.map((Object? id) => _song(textOf(id))).toList());
      };

      await libraryEnterDirectory(lib, container);
      // cursor=2 且仍有 id s3：走两步越过本页，触发 songs 分页请求。
      await libraryNavigateDirectory(lib, 2, 'row');

      expect(
        b.wire.calls.map((({String route, JsonMap params}) call) => call.route).toSet(),
        <String>{'/native/netease/detail', '/native/netease/songs'},
      );
      expect(lib.status, '已打开：目标歌单');
    });
  });
}
