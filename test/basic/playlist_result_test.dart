// `music:result:<lane>:<index>` 的接线契约。
//
// 真值来源（只读）：
//  - Qt 动作分派：`Qt/src/NativeHudMusic.cpp:157-163` 的 `name == "result"` →
//    `music.selectResult(parts.value(3).toInt(), parts.value(2).toInt());`
//    `tab = "overview"; trackOffset = 0; bodyOffset = 0; closeModal();`
//    —— `parts[2]` 是 lane、`parts[3]` 是 index，`selectResult` 默认 `open = true`。
//  - Qt 选中语义：`Qt/src/MusicLibrary.cpp:829-869`：`kind == "song"` 时进 detail，
//    其余（playlist/album/artist）走 `enterDirectory(current)` 留在 archive。
//  - 本机歌单曲目：`Qt/src/LocalCollections.cpp:164-176` 的 `tracks(id)` 从新到旧。
//
// 之前这里没有 handler，`_route` 落到 `basicUnimplementedPrefix`（点行只出
// 「尚未实现」提示），表现为「面板里点歌单没反应」。本文件钉住三件事：
// 1. 动作前缀常量与 HUD 发出来的载荷是同一个字面量；
// 2. `enterLocalPlaylist` 真的把歌单变成 `BasicDirectory(kind: 'playlist')`，且曲目
//    是 store 里那几首的真曲目（解析不到的 id 不编造）；
// 3. 空歌单也有可见状态串，不伪造「已打开」。
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:rhine_music_database/basic/basic_app.dart' show basicMusicResultActionPrefix;
import 'package:rhine_music_database/basic/basic_models.dart';
import 'package:rhine_music_database/basic/platform_playback.dart';
import 'package:rhine_music_database/basic/siren_controller.dart';
import 'package:rhine_music_database/basic/siren_repository.dart';
import 'package:rhine_music_database/data/storage/preference_store.dart';
import 'package:rhine_music_database/domain/collection/local_collection_store.dart';

Future<void> _settle() async {
  for (int i = 0; i < 24; i += 1) {
    await Future<void>.delayed(Duration.zero);
  }
}

SirenHttpResult _json(Object? body) =>
    SirenHttpResult(statusCode: 200, bytes: utf8.encode(jsonEncode(body)));

/// 假塞壬站点：三首曲目，够组成一张歌单。
class _Server {
  Future<SirenHttpResult> handle(Uri uri) async {
    if (uri.path == '/api/songs') {
      return _json(<String, Object?>{
        'code': 0,
        'data': <Object?>[
          for (final String id in <String>['s01', 's02', 's03'])
            <String, Object?>{
              'cid': id,
              'name': 'Song $id',
              'albumCid': 'a1',
              'artists': <Object?>['A'],
            },
        ],
      });
    }
    if (uri.path == '/api/albums') {
      return _json(<String, Object?>{
        'code': 0,
        'data': <Object?>[
          <String, Object?>{
            'cid': 'a1',
            'name': 'Album 1',
            'artistes': <Object?>['A'],
            'coverUrl': '',
          },
        ],
      });
    }
    return const SirenHttpResult(statusCode: 404, bytes: <int>[]);
  }

  SirenRepository repository() =>
      SirenRepository(baseUri: Uri.parse('https://example.test'), get: handle);
}

class _FakeAudio implements BasicAudioPort {
  final BasicAudioState _state = const BasicAudioState();
  final List<String> calls = <String>[];
  final List<void Function(BasicAudioState)> _listeners = <void Function(BasicAudioState)>[];

  @override
  BasicAudioState get state => _state;

  @override
  void addListener(void Function(BasicAudioState) listener) => _listeners.add(listener);

  @override
  void removeListener(void Function(BasicAudioState) listener) => _listeners.remove(listener);

  bool get played =>
      calls.any((String call) => call.startsWith('play:') || call.startsWith('prepare:'));

  @override
  Future<void> prepare(String url, {required int generation}) async {
    calls.add('prepare:$url:$generation');
  }

  @override
  Future<void> play({required int generation}) async => calls.add('play:$generation');

  @override
  Future<void> pause({required int generation}) async => calls.add('pause:$generation');

  @override
  Future<void> seekTo(double positionMs, {required int generation}) async =>
      calls.add('seek:${positionMs.toStringAsFixed(0)}');

  @override
  Future<void> stop() async => calls.add('stop');

  @override
  Future<void> dispose() async => calls.add('dispose');
}

/// 内存 [PreferencePort]：只落字符串键值，不碰文件系统。
class _MemoryPort implements PreferencePort {
  final Map<String, String> values = <String, String>{};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async => values[key] = value;

  @override
  Future<void> remove(String key) async => values.remove(key);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('动作前缀常量与 HUD 发出的载荷是同一个字面量', () {
    // portrait_pages_collection_playlists.dart 发 `'music:result:2:$index'`，
    // portrait_pages_collection_likes.dart 发 `'music:result:1:$index'`。
    expect(basicMusicResultActionPrefix, 'music:result:');
    expect('music:result:2:0'.startsWith(basicMusicResultActionPrefix), isTrue);
    expect('music:result:1:3'.startsWith(basicMusicResultActionPrefix), isTrue);
  });

  test('enterLocalPlaylist 把本机歌单变成 playlist 目录，曲目是从 store 解析出的真曲目',
      () async {
    final _MemoryPort port = _MemoryPort();
    final LocalCollectionStore store = LocalCollectionStore(port: port);
    await store.load();
    await store.createPlaylist('深夜循环');
    final String id = store.playlists().single.id;
    // Qt 的 `tracks(id)` 从新到旧：先加 s02 再加 s01，读回来应是 [s01, s02] 的逆序。
    await store.addTrack(id, 's02');
    await store.addTrack(id, 's01');

    final BasicController controller = BasicController(
      audio: _FakeAudio(),
      repository: _Server().repository(),
      collectionStore: store,
    );
    addTearDown(controller.dispose);
    await controller.boot();
    await _settle();

    final String notice = await controller.enterLocalPlaylist(
      store.playlists().single,
    );
    await _settle();

    // 成功路径不返回错误串（错误串由调用方 _setNotice 上屏）。
    expect(notice, '');
    final BasicViewState state = controller.state;
    final BasicDirectory directory = state.directory!;
    expect(directory.kind, 'playlist');
    expect(directory.title, '深夜循环');
    expect(directory.virtual, isFalse, reason: '本机歌单不是虚拟目录');
    expect(directory.description, '本地歌单 · 仅保存在本机');
    // store 里加的是 s02 再 s01 ⇒ playlistTrackIds 返回 [s01, s02]。
    expect(directory.ids, <String>['s01', 's02']);
    expect(directory.songs.length, 2, reason: '两首都能从曲库解析出来');
    expect(state.phase, BasicPhase.library, reason: 'Qt 里歌单行是 archive 不是 detail');
    expect(state.status, '已打开：深夜循环');
    expect(state.song?.id, 's01', reason: '只选中第一首，不播放');
  });

  test('空歌单：目录照开但状态串是诚实文案，不返回错误', () async {
    final _MemoryPort port = _MemoryPort();
    final LocalCollectionStore store = LocalCollectionStore(port: port);
    await store.load();
    await store.createPlaylist('空歌单');

    final BasicController controller = BasicController(
      audio: _FakeAudio(),
      repository: _Server().repository(),
      collectionStore: store,
    );
    addTearDown(controller.dispose);
    await controller.boot();
    await _settle();

    await controller.enterLocalPlaylist(store.playlists().single);
    await _settle();

    final BasicViewState state = controller.state;
    expect(state.directory?.title, '空歌单');
    expect(state.directory?.songs, isEmpty);
    expect(state.status, sirenEmptyPlaylistStatus);
    expect(state.song, isNull, reason: '没有曲目就没有当前曲目，不能编造');
  });

  test('没有本机收藏端口时给出可见错误串，不开目录', () async {
    final BasicController controller = BasicController(
      audio: _FakeAudio(),
      repository: _Server().repository(),
    );
    addTearDown(controller.dispose);
    await controller.boot();
    await _settle();

    final String notice = await controller.enterLocalPlaylist(
      const BasicLocalPlaylist(id: 'pl-1', title: '深夜循环'),
    );
    expect(notice, '本地收藏尚未接入');
    expect(controller.state.directory, isNull);
  });
}
