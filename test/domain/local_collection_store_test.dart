// 本机收藏（喜欢的歌曲 + 我的歌单）数据层测试。
//
// 存储后端是注入的 `PreferencePort`，所以这里只用一个内存 Map 替身：不碰文件系统、
// 不碰 Flutter，纯 Dart 逻辑。每条断言的语义都对齐 Qt/src/LocalCollections.cpp 的
// 对应行为（注释里给出依据），覆盖任务书要求的六类场景，外加落盘文档形状与容错载入。
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:rhine_music_database/basic/basic_models.dart';
import 'package:rhine_music_database/data/storage/preference_store.dart';
import 'package:rhine_music_database/domain/collection/local_collection_store.dart';

/// 内存 [PreferencePort]：与真实后端一样按 key 读写字符串，并记录写次数，
/// 用来断言「幂等操作不重复落盘」。
class MemoryPort implements PreferencePort {
  MemoryPort([Map<String, String>? initial])
      : values = <String, String>{...?initial};

  final Map<String, String> values;
  final List<String> writes = <String>[];

  int get writeCount => writes.length;

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

/// 递增时钟：让 `createdAt` 严格递增，歌单顺序可断言（Qt 用
/// `QDateTime::currentMSecsSinceEpoch()`，LocalCollections.cpp:185）。
DateTime Function() _ticking(int start) {
  int current = start;
  return () {
    current += 1000;
    return DateTime.fromMillisecondsSinceEpoch(current);
  };
}

Future<LocalCollectionStore> _loaded(
  MemoryPort port, {
  DateTime Function()? clock,
}) async {
  final LocalCollectionStore store = LocalCollectionStore(
    port: port,
    clock: clock ?? _ticking(1700000000000),
  );
  await store.load();
  return store;
}

Map<String, Object?> _document(MemoryPort port) {
  final String? raw = port.values[LocalCollectionStore.keyPrefix + 'siren.json'];
  expect(raw, isNotNull, reason: '写入后必须存在 collections/siren.json 这个键');
  return jsonDecode(raw!) as Map<String, Object?>;
}

void main() {
  group('喜欢', () {
    test('like/unlike 往返：likedIds 从新到旧，likedCount 同步，status 用 Qt 文案', () async {
      final MemoryPort port = MemoryPort();
      final LocalCollectionStore store = await _loaded(port);

      expect(await store.toggleLike('song-a'), isTrue);
      expect(await store.toggleLike('song-b'), isTrue);
      expect(store.isLiked('song-a'), isTrue);
      expect(store.likedCount, 2);
      // LocalCollections.cpp:87-94：存储按添加顺序，读取反转为新→旧。
      expect(store.likedIds(), <String>['song-b', 'song-a']);
      expect(store.status, '已加入喜欢的歌曲');

      expect(await store.toggleLike('song-a'), isFalse);
      expect(store.isLiked('song-a'), isFalse);
      expect(store.likedIds(), <String>['song-b']);
      expect(store.likedCount, 1);
      expect(store.status, '已从喜欢的歌曲移除');

      await store.unlike('song-b');
      expect(store.likedIds(), isEmpty);
      expect(store.likedCount, 0);
    });

    test('重复 like / 重复 unlike 幂等：不产生重复项，也不重复写盘', () async {
      final MemoryPort port = MemoryPort();
      final LocalCollectionStore store = await _loaded(port);

      await store.like('song-a');
      final int afterFirst = port.writeCount;
      await store.like('song-a');
      expect(store.likedIds(), <String>['song-a']);
      // LocalCollections.cpp:109-119：已存在且 liked 直接 return true，不 save()。
      expect(port.writeCount, afterFirst);

      await store.unlike('song-a');
      final int afterRemove = port.writeCount;
      await store.unlike('song-a');
      expect(store.likedIds(), isEmpty);
      // LocalCollections.cpp:120-122：不存在且 !liked 也直接 return true。
      expect(port.writeCount, afterRemove);
    });

    test('空 id 写不进收藏，并留下 Qt 的失败文案', () async {
      final MemoryPort port = MemoryPort();
      final LocalCollectionStore store = await _loaded(port);

      expect(await store.toggleLike(''), isFalse);
      expect(store.likedIds(), isEmpty);
      // MusicMutation.cpp：setLiked 返回 false 时 status = 无法写入本地收藏。
      expect(store.status, '无法写入本地收藏');
      expect(port.writeCount, 0);
    });
  });

  group('歌单', () {
    test('创建/改名/删除：新歌单在最前，trackCount 归零，status 逐条对齐', () async {
      final MemoryPort port = MemoryPort();
      final LocalCollectionStore store = await _loaded(port);

      final BasicLocalPlaylist first = await store.createPlaylist(' 第一张 ');
      expect(first.id, isNotEmpty);
      expect(first.title, '第一张', reason: '名称要去掉首尾空白（Qt trims）');
      expect(first.trackCount, 0);
      expect(store.status, '已创建歌单：第一张');

      final BasicLocalPlaylist second = await store.createPlaylist('第二张');
      // LocalCollections.cpp:187：新记录 prepend 到头部。
      expect(
        store.playlists().map((BasicLocalPlaylist p) => p.title),
        <String>['第二张', '第一张'],
      );

      await store.renamePlaylist(first.id, '改过了');
      expect(store.status, '已重命名歌单');
      expect(
        store.playlists().map((BasicLocalPlaylist p) => p.title),
        <String>['第二张', '改过了'],
      );

      await store.deletePlaylist(second.id);
      expect(store.status, '已删除歌单');
      expect(store.playlists().single.title, '改过了');
    });

    test('加曲/移曲：playlistTrackIds 从新到旧，playlists() 的 trackCount 跟着变', () async {
      final MemoryPort port = MemoryPort();
      final LocalCollectionStore store = await _loaded(port);
      final BasicLocalPlaylist playlist = await store.createPlaylist('混音');

      await store.addTrack(playlist.id, 'song-1');
      await store.addTrack(playlist.id, 'song-2');
      // LocalCollections.cpp:164-176：曲目也按加入顺序存、读取反转为新→旧。
      expect(store.playlistTrackIds(playlist.id), <String>['song-2', 'song-1']);
      expect(store.playlists().single.trackCount, 2);

      await store.removeTrack(playlist.id, 'song-1');
      expect(store.playlistTrackIds(playlist.id), <String>['song-2']);
      expect(store.playlists().single.trackCount, 1);

      // LocalCollections.cpp:241-250：找不到曲目也返回 true（不算失败）。
      await store.removeTrack(playlist.id, 'song-missing');
      expect(store.playlistTrackIds(playlist.id), <String>['song-2']);
    });

    test('非法 id / 重复操作：不抛异常、不编数据，status 记 Qt 失败文案', () async {
      final MemoryPort port = MemoryPort();
      final LocalCollectionStore store = await _loaded(port);
      final BasicLocalPlaylist playlist = await store.createPlaylist('列表');

      // 未知歌单：加曲/移曲都不该写盘也不该出现内容。
      await store.addTrack('no-such-playlist', 'song-1');
      expect(store.status, '无法写入本地歌单');
      await store.removeTrack('no-such-playlist', 'song-1');
      expect(store.status, '无法写入本地歌单');
      expect(store.playlistTrackIds('no-such-playlist'), isEmpty);

      // trackId 为空：LocalCollections.cpp:217 直接 false。
      await store.addTrack(playlist.id, '');
      expect(store.status, '无法写入本地歌单');
      expect(store.playlistTrackIds(playlist.id), isEmpty);

      // 重复加曲幂等：不产生第二份。
      await store.addTrack(playlist.id, 'song-1');
      final int afterFirst = port.writeCount;
      await store.addTrack(playlist.id, 'song-1');
      expect(store.playlistTrackIds(playlist.id), <String>['song-1']);
      expect(port.writeCount, afterFirst);

      // 未知 id 的改名/删除：不写盘，留下失败文案。
      await store.renamePlaylist('no-such-playlist', '新名字');
      expect(store.status, '无法重命名歌单');
      await store.deletePlaylist('no-such-playlist');
      expect(store.status, '无法删除歌单');
      expect(store.playlists().single.title, '列表');
    });

    test('名称上限 100 码点、歌单上限 200 张：拒绝返回空 id（Qt 返回空对象）', () async {
      final MemoryPort port = MemoryPort();
      final LocalCollectionStore store = await _loaded(port);

      expect(await store.createPlaylist('   '), LocalCollectionStore.emptyPlaylist);
      expect(store.status, '请输入 1–100 字歌单名称');
      expect(await store.createPlaylist('名' * 101), LocalCollectionStore.emptyPlaylist);
      expect(await store.createPlaylist('名' * 100), isNot(LocalCollectionStore.emptyPlaylist));
      expect(store.playlists().single.title.runes.length, 100);

      for (int i = 1; i < LocalCollectionStore.maxPlaylists; i++) {
        await store.createPlaylist('批量 $i');
      }
      expect(store.playlists().length, LocalCollectionStore.maxPlaylists);
      // LocalCollections.cpp:180：m_playlists.size() >= 200 时拒绝。
      expect(await store.createPlaylist('第 201 张'), LocalCollectionStore.emptyPlaylist);
      expect(store.playlists().length, LocalCollectionStore.maxPlaylists);
    });
  });

  group('持久化', () {
    test('写盘文档与 Qt 逐字段同形：version / provider / liked / playlists', () async {
      final MemoryPort port = MemoryPort();
      final LocalCollectionStore store = await _loaded(port);
      await store.like('song-a');
      final BasicLocalPlaylist playlist = await store.createPlaylist('清晨');
      await store.addTrack(playlist.id, 'song-a');

      expect(store.storageKey, 'collections/siren.json');
      final Map<String, Object?> document = _document(port);
      // LocalCollections.cpp:81-82：{"version":1,"provider":…,"liked":…,"playlists":…}
      expect(document.keys.toList(), <String>['version', 'provider', 'liked', 'playlists']);
      expect(document['version'], 1);
      expect(document['provider'], sirenProvider);
      expect(document['liked'], <Object?>['song-a']);
      final Map<String, Object?> record =
          (document['playlists']! as List<Object?>).single! as Map<String, Object?>;
      // LocalCollections.cpp:48-58 的字段名：id / name / createdAt / trackIDs。
      expect(record.keys.toList(), <String>['id', 'name', 'createdAt', 'trackIDs']);
      expect(record['id'], playlist.id);
      expect(record['name'], '清晨');
      expect(record['createdAt'], isA<int>());
      expect(record['trackIDs'], <Object?>['song-a']);
    });

    test('跨实例：同一 port 重新 load 后收藏与歌单仍在', () async {
      final MemoryPort port = MemoryPort();
      final DateTime Function() clock = _ticking(1700000000000);
      final LocalCollectionStore first = await _loaded(port, clock: clock);
      await first.like('song-a');
      final BasicLocalPlaylist created = await first.createPlaylist('跨实例');
      await first.addTrack(created.id, 'song-a');
      await first.addTrack(created.id, 'song-b');

      final LocalCollectionStore second = await _loaded(port, clock: clock);
      expect(second.likedIds(), <String>['song-a']);
      expect(second.likedCount, 1);
      expect(second.playlists().single.id, created.id);
      expect(second.playlists().single.title, '跨实例');
      expect(second.playlists().single.trackCount, 2);
      expect(second.playlistTrackIds(created.id), <String>['song-b', 'song-a']);
    });

    test('载入 Qt 写的文档：去重、跳过空 name、按 createdAt 降序、坏数据当空', () async {
      final MemoryPort port = MemoryPort(<String, String>{
        'collections/siren.json': jsonEncode(<String, Object?>{
          'version': 1,
          'provider': 'siren',
          'liked': <Object?>['song-a', '', 'song-a', 'song-b'],
          'playlists': <Object?>[
            <String, Object?>{
              'id': 'old',
              'name': '旧歌单',
              'createdAt': 1000,
              'trackIDs': <Object?>['t1', 't1', 't2'],
            },
            <String, Object?>{'id': '', 'name': '没有 id', 'createdAt': 2000},
            <String, Object?>{'id': 'blank', 'name': '   ', 'createdAt': 2000},
            <String, Object?>{
              'id': 'new',
              'name': ' 新歌单 ',
              'createdAt': 3000,
              'trackIDs': <Object?>[],
            },
          ],
        }),
      });
      final LocalCollectionStore store = await _loaded(port);

      // strings()：过滤空串并去重（LocalCollections.cpp:23-34）。
      expect(store.likedIds(), <String>['song-b', 'song-a']);
      // id/name 空的条目被跳过；name 去空白；createdAt 降序。
      expect(
        store.playlists().map((BasicLocalPlaylist p) => p.title),
        <String>['新歌单', '旧歌单'],
      );
      expect(store.playlistTrackIds('old'), <String>['t2', 't1']);

      // 坏 JSON / 版本不符 / provider 不符：静默当空，不抛、不回写。
      for (final String raw in <String>[
        'not json',
        jsonEncode(<String, Object?>{'version': 2, 'provider': 'siren'}),
        jsonEncode(<String, Object?>{'version': 1, 'provider': 'netease'}),
      ]) {
        final MemoryPort broken = MemoryPort(<String, String>{
          'collections/siren.json': raw,
        });
        final LocalCollectionStore empty = await _loaded(broken);
        expect(empty.likedIds(), isEmpty);
        expect(empty.playlists(), isEmpty);
        expect(broken.writeCount, 0, reason: '载入失败不得回写');
      }
    });

    test('空状态：全新 store 的读数与 status 都是空', () async {
      final MemoryPort port = MemoryPort();
      final LocalCollectionStore store = await _loaded(port);

      expect(store.likedIds(), isEmpty);
      expect(store.likedCount, 0);
      expect(store.playlists(), isEmpty);
      expect(store.isLiked('song-a'), isFalse);
      expect(store.playlistTrackIds('anything'), isEmpty);
      expect(store.status, '');
      expect(port.writeCount, 0);
    });
  });
}
