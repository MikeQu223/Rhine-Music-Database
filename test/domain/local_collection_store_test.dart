// 本机收藏（喜欢 + 歌单）存储的领域层测试。
//
// 存储后端是注入的 PreferencePort，所以这里只用一个内存 Map 假实现：不碰文件
// 系统、不碰 Flutter，纯 Dart 逻辑。覆盖：喜欢写入/取消/去重、歌单 id 递增、
// 重命名、删除、加歌去重、移除计数、损坏 JSON 容错、跨实例持久化、标题校验。

import 'package:flutter_test/flutter_test.dart';

import 'package:rhine_music_database/data/storage/preference_store.dart';
import 'package:rhine_music_database/domain/collection/local_collection_store.dart';

/// 内存 PreferencePort：与真实后端一样按 key 读写字符串。
class MemoryPort implements PreferencePort {
  MemoryPort({Map<String, String>? initial})
      : values = <String, String>{...?initial};

  final Map<String, String> values;
  final List<String> writes = <String>[];

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async {
    writes.add(key);
    values[key] = value;
  }

  @override
  Future<void> remove(String key) async {
    values.remove(key);
  }
}

Future<LocalCollectionStore> loadedStore(MemoryPort port) async {
  final store = LocalCollectionStore(preferences: port);
  await store.load();
  return store;
}

void main() {
  group('喜欢', () {
    test('写入后 isLiked 为真且列表有序，取消后移除', () async {
      final port = MemoryPort();
      final store = await loadedStore(port);

      await store.setLiked('track-a', true);
      await store.setLiked('track-b', true);
      expect(store.likedIds, <String>['track-a', 'track-b']);
      expect(store.isLiked('track-a'), isTrue);
      expect(store.isLiked('track-z'), isFalse);

      await store.setLiked('track-a', false);
      expect(store.likedIds, <String>['track-b']);
      expect(store.isLiked('track-a'), isFalse);
    });

    test('重复喜欢同一个 id 不产生重复项', () async {
      final port = MemoryPort();
      final store = await loadedStore(port);

      await store.setLiked('track-x', true);
      await store.setLiked('track-x', true);
      expect(store.likedIds, <String>['track-x']);

      await store.setLiked('track-x', false);
      expect(store.likedIds, isEmpty);
    });

    test('持久化为 JSON 字符串数组', () async {
      final port = MemoryPort();
      final store = await loadedStore(port);
      await store.setLiked('track-1', true);

      expect(port.values[LocalCollectionStore.likedIdsKey], '["track-1"]');
    });

    test('损坏的喜欢 JSON 容错为空', () async {
      final port = MemoryPort(
        initial: <String, String>{
          LocalCollectionStore.likedIdsKey: '{"not": "a list"',
        },
      );
      final store = await loadedStore(port);

      expect(store.likedIds, isEmpty);
      expect(store.isLiked('anything'), isFalse);
    });
  });

  group('歌单', () {
    test('创建歌单 id 序号递增且标题 trim', () async {
      final port = MemoryPort();
      final store = await loadedStore(port);

      final first = await store.createPlaylist('  夜跑  ');
      expect(first.id, 'local-playlist-1');
      expect(first.title, '夜跑');
      expect(first.trackCount, 0);

      final second = await store.createPlaylist('通勤');
      expect(second.id, 'local-playlist-2');
      expect(store.playlists.map((p) => p.id), <String>[
        'local-playlist-1',
        'local-playlist-2',
      ]);
    });

    test('标题 trim 后为空抛 ArgumentError', () async {
      final port = MemoryPort();
      final store = await loadedStore(port);

      await expectLater(store.createPlaylist('   '), throwsArgumentError);
      await expectLater(
        store.renamePlaylist('missing', '  '),
        throwsArgumentError,
      );
    });

    test('重命名只改标题并保持顺序', () async {
      final port = MemoryPort();
      final store = await loadedStore(port);
      await store.createPlaylist('旧名');
      await store.createPlaylist('另一个');

      await store.renamePlaylist('local-playlist-1', ' 新名 ');
      expect(store.playlists.first.title, '新名');
      expect(store.playlists.first.id, 'local-playlist-1');
      expect(store.playlists.last.title, '另一个');
    });

    test('删除返回 true 且未知 id 返回 false', () async {
      final port = MemoryPort();
      final store = await loadedStore(port);
      await store.createPlaylist('可删');

      expect(await store.removePlaylist('local-playlist-1'), isTrue);
      expect(store.playlists, isEmpty);
      expect(await store.removePlaylist('local-playlist-1'), isFalse);
    });

    test('加歌去重：已存在的不重复加，含批内重复', () async {
      final port = MemoryPort();
      final store = await loadedStore(port);
      await store.createPlaylist('列表');

      await store.addToPlaylist(
        playlistId: 'local-playlist-1',
        trackIds: <String>['t1', 't2'],
      );
      await store.addToPlaylist(
        playlistId: 'local-playlist-1',
        trackIds: <String>['t2', 't3', 't3'],
      );

      expect(store.playlists.single.trackIds, <String>['t1', 't2', 't3']);
      expect(store.playlists.single.trackCount, 3);
    });

    test('移除返回真实移除条数', () async {
      final port = MemoryPort();
      final store = await loadedStore(port);
      await store.createPlaylist('列表');
      await store.addToPlaylist(
        playlistId: 'local-playlist-1',
        trackIds: <String>['t1', 't2', 't3'],
      );

      expect(
        await store.removeFromPlaylist(
          playlistId: 'local-playlist-1',
          trackIds: <String>['t1', 't3', 'absent'],
        ),
        2,
      );
      expect(store.playlists.single.trackIds, <String>['t2']);

      expect(
        await store.removeFromPlaylist(
          playlistId: 'local-playlist-1',
          trackIds: <String>['t2', 't2'],
        ),
        1,
      );
      expect(store.playlists.single.trackIds, isEmpty);
      expect(
        await store.removeFromPlaylist(
          playlistId: 'missing',
          trackIds: <String>['t1'],
        ),
        0,
      );
    });

    test('损坏的歌单 JSON 或错误形状容错为空', () async {
      final port = MemoryPort(
        initial: <String, String>{
          LocalCollectionStore.playlistsKey: '[{"id": 1,',
        },
      );
      final store = await loadedStore(port);

      expect(store.playlists, isEmpty);
    });

    test('歌单数组里非对象条目被跳过', () async {
      final port = MemoryPort(
        initial: <String, String>{
          LocalCollectionStore.playlistsKey:
              '[42, {"id":"local-playlist-3","title":"保留","trackIds":["t1",2]}]',
        },
      );
      final store = await loadedStore(port);

      expect(store.playlists.length, 1);
      expect(store.playlists.single.title, '保留');
      expect(store.playlists.single.trackIds, <String>['t1']);
      // 新 id 序号接在最大的 local-playlist-3 之后。
      final created = await store.createPlaylist('新增');
      expect(created.id, 'local-playlist-4');
    });
  });

  group('持久化', () {
    test('跨实例：同一内存 port 重建 store 后状态一致', () async {
      final port = MemoryPort();
      final first = await loadedStore(port);
      await first.setLiked('track-1', true);
      await first.createPlaylist('跨实例');
      await first.addToPlaylist(
        playlistId: 'local-playlist-1',
        trackIds: <String>['track-1', 'track-2'],
      );

      final second = await loadedStore(port);
      expect(second.likedIds, <String>['track-1']);
      expect(second.playlists.length, 1);
      expect(second.playlists.single.id, 'local-playlist-1');
      expect(second.playlists.single.title, '跨实例');
      expect(second.playlists.single.trackIds, <String>['track-1', 'track-2']);
    });

    test('LocalPlaylist toJson/fromJson 往返与 copyWith', () {
      const original = LocalPlaylist(
        id: 'local-playlist-7',
        title: '往返',
        trackIds: <String>['a', 'b'],
      );
      final roundTrip = LocalPlaylist.fromJson(original.toJson());

      expect(roundTrip.id, original.id);
      expect(roundTrip.title, original.title);
      expect(roundTrip.trackIds, original.trackIds);
      expect(roundTrip.trackCount, 2);

      expect(original.copyWith(title: '新').id, 'local-playlist-7');
      expect(original.copyWith().trackIds, original.trackIds);

      // 缺失/错误类型字段降级为空值而不是抛异常。
      final broken = LocalPlaylist.fromJson(<Object?, Object?>{'id': 1});
      expect(broken.id, '');
      expect(broken.title, '');
      expect(broken.trackIds, isEmpty);
    });
  });
}
