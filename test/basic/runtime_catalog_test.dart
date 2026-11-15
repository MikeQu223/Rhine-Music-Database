import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:rhine_music_database/basic/basic_models.dart';
import 'package:rhine_music_database/basic/platform_playback.dart';
import 'package:rhine_music_database/basic/siren_controller.dart';
import 'package:rhine_music_database/basic/siren_repository.dart';

/// 只记录调用的音频端口：曲库接线测试不接平台通道、不出声。
class _SilentAudio implements BasicAudioPort {
  final List<void Function(BasicAudioState)> _listeners =
      <void Function(BasicAudioState)>[];
  BasicAudioState _state = BasicAudioState.idle;

  @override
  BasicAudioState get state => _state;

  @override
  void addListener(void Function(BasicAudioState) listener) =>
      _listeners.add(listener);

  @override
  void removeListener(void Function(BasicAudioState) listener) =>
      _listeners.remove(listener);

  @override
  Future<void> prepare(String url, {required int generation}) async {}

  @override
  Future<void> play({required int generation}) async {}

  @override
  Future<void> pause({required int generation}) async {}

  @override
  Future<void> seekTo(double positionMs, {required int generation}) async {}

  @override
  Future<void> stop() async {}

  @override
  Future<void> dispose() async {
    _listeners.clear();
  }
}

/// 官网真实 wire 形状：{ code: 0, data: [...] }。
SirenRepository _repository(List<String> requested) {
  return SirenRepository(
    get: (Uri uri) async {
      requested.add(uri.path);
      final Map<String, Object?> payload = switch (uri.path) {
        '/api/songs' => <String, Object?>{
            'code': 0,
            'data': <Object?>[
              <String, Object?>{
                'cid': 's1',
                'name': '第一首',
                'albumCid': 'a1',
                'artists': <String>['歌手甲'],
              },
              <String, Object?>{
                'cid': 's2',
                'name': '第二首',
                'albumCid': 'a1',
                'artists': <String>['歌手甲'],
              },
            ],
          },
        '/api/albums' => <String, Object?>{
            'code': 0,
            'data': <Object?>[
              <String, Object?>{
                'cid': 'a1',
                'name': '专辑一',
                'coverUrl': 'https://example.invalid/a1.png',
                'artistes': <String>['歌手甲'],
              },
            ],
          },
        _ => <String, Object?>{'code': 404, 'msg': 'unexpected ${uri.path}'},
      };
      return SirenHttpResult(
        statusCode: 200,
        bytes: utf8.encode(jsonEncode(payload)),
      );
    },
  );
}

void main() {
  test('boot 读一次真实 wire 形状的曲库，重复 boot 不再请求', () async {
    final List<String> requested = <String>[];
    final BasicController controller = BasicController(
      audio: _SilentAudio(),
      repository: _repository(requested),
    );
    addTearDown(controller.dispose);

    expect(controller.state.catalogLoaded, isFalse);
    await controller.boot();

    expect(requested.toSet(), <String>{'/api/songs', '/api/albums'});
    expect(requested.length, 2);
    expect(controller.state.catalogLoaded, isTrue);
    expect(controller.state.phase, BasicPhase.library);
    expect(
      controller.state.songs.map((SirenSong song) => song.title).toList(),
      <String>['第一首', '第二首'],
    );
    expect(controller.state.albums.single.name, '专辑一');
    expect(controller.state.albums.single.songs.length, 2);
    expect(controller.state.status, startsWith(sirenCatalogLoadedPrefix));

    await controller.boot();
    expect(requested.length, 2);
  });

  test('搜索走真实 setQuery 过滤；open-all-siren 回到完整曲库', () async {
    final List<String> requested = <String>[];
    final BasicController controller = BasicController(
      audio: _SilentAudio(),
      repository: _repository(requested),
    );
    addTearDown(controller.dispose);
    await controller.boot();

    await controller.setQuery('第一');
    expect(controller.state.query, '第一');
    expect(
      controller.state.songs.map((SirenSong song) => song.id).toList(),
      <String>['s1'],
    );
    expect(controller.state.status, contains('1'));

    await controller.setQuery('没有这首');
    expect(controller.state.songs, isEmpty);
    expect(controller.state.status, '没有匹配的音乐');

    // archive 页 'music:open-all-siren' 的落点：清检索、回完整曲库，不打断播放队列。
    await controller.openSirenLibrary();
    expect(controller.state.query, '');
    expect(controller.state.phase, BasicPhase.library);
    expect(controller.state.songs.length, 2);
    expect(controller.state.status, startsWith(sirenCatalogLoadedPrefix));
  });

  group('openAllSirenSongs（Qt/src/MusicSiren.cpp:193-246）', () {
    test('用真实曲库建「全部歌曲」目录，字段逐字对齐 Qt', () async {
      final List<String> requested = <String>[];
      final BasicController controller = BasicController(
        audio: _SilentAudio(),
        repository: _repository(requested),
      );
      addTearDown(controller.dispose);
      await controller.boot();

      await controller.openAllSirenSongs();

      final BasicDirectory? directory = controller.state.directory;
      expect(directory, isNotNull);
      expect(directory!.provider, sirenProvider);
      expect(directory.kind, 'playlist');
      expect(directory.virtual, isTrue);
      expect(directory.id, sirenAllSongsId);
      expect(directory.key, sirenAllSongsKey);
      expect(directory.title, '全部歌曲');
      expect(directory.artist, '塞壬唱片', reason: 'Qt MusicApi::providerName(siren) 的原文');
      expect(directory.description, '塞壬唱片全部歌曲');
      expect(directory.cover, controller.state.songs.first.cover);
      expect(directory.trackCount, 2);
      expect(directory.ids, <String>['s1', 's2']);
      expect(directory.cursor, 2);
      expect(directory.index, 0);
      expect(directory.parent, isNull);
      expect(
        directory.songs.map((SirenSong song) => song.id).toList(),
        <String>['s1', 's2'],
      );

      expect(controller.state.phase, BasicPhase.library);
      expect(controller.state.status, '已打开：全部歌曲');
      expect(controller.state.songs.length, 2);
      expect(controller.state.albums, isEmpty, reason: '目录内只列曲目');
      // Qt :243-245：current 清空后只 choose 第一首——选中，不播放，队列保持空。
      expect(controller.state.song?.id, 's1');
      expect(controller.state.queue, isEmpty);
      expect(controller.state.playing, isFalse);
      expect(requested.length, 2, reason: '目录用已加载的曲库，不再发请求');
    });

    test('曲库未加载：只上屏未加载文案，不造空目录', () async {
      final BasicController controller = BasicController(
        audio: _SilentAudio(),
        repository: _repository(<String>[]),
      );
      addTearDown(controller.dispose);

      await controller.openAllSirenSongs();

      expect(controller.state.directory, isNull);
      expect(controller.state.songs, isEmpty);
      expect(controller.state.status, sirenLibraryUnloadedStatus);
    });

    test('重复打开：新目录以旧目录为 parent，back 逐级返回', () async {
      final List<String> requested = <String>[];
      final BasicController controller = BasicController(
        audio: _SilentAudio(),
        repository: _repository(requested),
      );
      addTearDown(controller.dispose);
      await controller.boot();

      await controller.openAllSirenSongs();
      await controller.openAllSirenSongs();
      expect(controller.state.directory?.parent?.id, sirenAllSongsId);

      await controller.back();
      expect(controller.state.directory?.id, sirenAllSongsId);
      expect(controller.state.status, '已返回：全部歌曲');

      await controller.back();
      expect(controller.state.directory, isNull);
      expect(controller.state.status, '已返回：塞壬唱片');
      expect(controller.state.phase, BasicPhase.library);
      expect(controller.state.songs.length, 2);
    });

    test('目录内搜索先离开目录，关键词作用于完整曲库', () async {
      final List<String> requested = <String>[];
      final BasicController controller = BasicController(
        audio: _SilentAudio(),
        repository: _repository(requested),
      );
      addTearDown(controller.dispose);
      await controller.boot();
      await controller.openAllSirenSongs();

      await controller.setQuery('第二');

      expect(controller.state.directory, isNull);
      expect(
        controller.state.songs.map((SirenSong song) => song.id).toList(),
        <String>['s2'],
      );
      expect(controller.state.status, '找到 1 条结果');
    });
  });
}
