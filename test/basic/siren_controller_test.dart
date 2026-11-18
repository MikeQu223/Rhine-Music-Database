/// BASIC-89 lane A · BasicController 测试（唯一 authority / 歌词跟随 / 真实进度）。
///
/// 本文件**只编写、不执行**：RED/GREEN 均未运行（禁令：禁 dart test / flutter test / analyze /
/// format / pub get / 构建 / 设备运行）。
///
/// 审查要点（协调者 seq5 裁决）：
///  - 3a：ticker 只在 boot() 启动、dispose() 必 cancel；LyricsController 尚未创建时 _pump 不做歌词调用。
///  - 3b：seekToFraction 只下发命令 + 用 native 已报时长重算歌词行，绝不本地改 position。
///  - pumpForTest 必须只是 100ms Timer 的同链路替身，不得产生 position += dt 的假进度。
///
/// 真值来源（只读）：
/// - Qt/src/MusicSiren.cpp:36-88 / :100-124 / :170-183 / :195 / :242；
/// - Qt/src/MusicLibrary.cpp:138 / :339；Qt/src/MusicPlayer.cpp:289 / :429 / :591-628；
/// - Qt/src/AudioPlayer.cpp:430-443（position/duration 为毫秒）；
/// - MusicBridge/client/siren.mjs:310-316 / :482-495 / :497-513；
/// - lib/domain/player/music_player.dart:350-439 / :467-489 / :591-628；
/// - lib/domain/lyrics/lyrics_controller.dart:197-268。
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:rhine_music_database/basic/basic_models.dart';
import 'package:rhine_music_database/basic/platform_playback.dart';
import 'package:rhine_music_database/basic/siren_controller.dart';
import 'package:rhine_music_database/basic/siren_repository.dart';

/// 让所有排队的微任务/零延迟 Future 走完（沿用 test/domain/siren_catalog_test.dart 的写法）。
Future<void> _settle() async {
  for (int i = 0; i < 16; i += 1) {
    await Future<void>.delayed(Duration.zero);
  }
}

SirenHttpResult _json(Object? body, {int statusCode = 200}) {
  return SirenHttpResult(statusCode: statusCode, bytes: utf8.encode(jsonEncode(body)));
}

SirenHttpResult _text(String body, {int statusCode = 200}) {
  return SirenHttpResult(statusCode: statusCode, bytes: utf8.encode(body));
}

/// 假的 BasicAudioPort（lane B 的真实实现要真机 MediaPlayer，测试只验证 Dart 侧契约）。
class _FakeAudio implements BasicAudioPort {
  BasicAudioState _state = const BasicAudioState();
  final List<String> calls = <String>[];
  final List<void Function(BasicAudioState)> _listeners = <void Function(BasicAudioState)>[];

  @override
  BasicAudioState get state => _state;

  @override
  void addListener(void Function(BasicAudioState) listener) {
    _listeners.add(listener);
  }

  @override
  void removeListener(void Function(BasicAudioState) listener) {
    _listeners.remove(listener);
  }

  void emit(BasicAudioState next) {
    _state = next;
    for (final void Function(BasicAudioState) listener
        in List<void Function(BasicAudioState)>.of(_listeners)) {
      listener(next);
    }
  }

  void clearCalls() => calls.clear();

  @override
  Future<void> prepare(String url, {required int generation}) async {
    calls.add('prepare:' + url + ':' + generation.toString());
    emit(BasicAudioState(buffering: true, generation: generation));
  }

  @override
  Future<void> play({required int generation}) async {
    calls.add('play:' + generation.toString());
  }

  @override
  Future<void> pause({required int generation}) async {
    calls.add('pause:' + generation.toString());
  }

  @override
  Future<void> seekTo(double positionMs, {required int generation}) async {
    calls.add('seek:' + positionMs.toStringAsFixed(0) + ':' + generation.toString());
  }

  @override
  Future<void> stop() async {
    calls.add('stop');
  }

  @override
  Future<void> dispose() async {
    calls.add('dispose');
  }
}

/// 假塞壬站点：只回真协议形状（code:0 + data），不触网。
class _Server {
  int songsStatus = 200;
  int albumsStatus = 200;
  bool emptyCatalog = false;
  int lyricStatus = 200;
  int albumDetailStatus = 200;
  String lyricText = '[00:00.00]line0\n[00:01.00]line1\n[00:05.00]line2';
  String albumName = 'Album One';
  String Function(String id) sourceFor = _defaultSource;
  String Function(String id) lyricFor = _defaultLyric;

  static String _defaultSource(String id) => 'https://file.test/' + id + '.flac';
  static String _defaultLyric(String id) => 'https://file.test/' + id + '.lrc';

  /// 覆盖整条路径（迟到响应/世代测试用）。
  Future<SirenHttpResult> Function(Uri uri)? override;

  final List<Uri> calls = <Uri>[];

  Future<SirenHttpResult> handle(Uri uri) async {
    calls.add(uri);
    final Future<SirenHttpResult> Function(Uri uri)? custom = override;
    if (custom != null) {
      return custom(uri);
    }
    if (uri.path == '/api/songs') {
      if (songsStatus != 200) {
        return const SirenHttpResult(statusCode: 500, bytes: <int>[]);
      }
      return _json(<String, Object?>{
        'code': 0,
        'data': emptyCatalog ? <Object?>[] : <Object?>[
          <String, Object?>{'cid': 's1', 'name': 'Song One', 'albumCid': 'a1', 'artists': <Object?>['A']},
          <String, Object?>{'cid': 's2', 'name': 'Song Two', 'albumCid': 'a1', 'artists': <Object?>['A']},
          <String, Object?>{'cid': 's3', 'name': 'Song Three', 'albumCid': 'a2', 'artists': <Object?>['B']},
        ],
      });
    }
    if (uri.path == '/api/albums') {
      if (albumsStatus != 200) {
        return const SirenHttpResult(statusCode: 500, bytes: <int>[]);
      }
      return _json(<String, Object?>{
        'code': 0,
        'data': emptyCatalog ? <Object?>[] : <Object?>[
          <String, Object?>{
            'cid': 'a1',
            'name': 'Album One',
            'artistes': <Object?>['A'],
            'coverUrl': 'https://cover.test/a1.jpg',
          },
          <String, Object?>{
            'cid': 'a2',
            'name': 'Album Two',
            'artistes': <Object?>['B'],
            'coverUrl': 'https://cover.test/a2.jpg',
          },
        ],
      });
    }
    if (uri.path.startsWith('/api/song/')) {
      final String id = uri.path.substring('/api/song/'.length);
      return _json(<String, Object?>{
        'code': 0,
        'data': <String, Object?>{
          'name': 'Song ' + id,
          'sourceUrl': sourceFor(id),
          'lyricUrl': lyricFor(id),
        },
      });
    }
    if (uri.path == '/api/album/a1/detail') {
      if (albumDetailStatus != 200) {
        return _json(<String, Object?>{'code': 500, 'msg': '服务异常'});
      }
      return _json(<String, Object?>{
        'code': 0,
        'data': <String, Object?>{
          'name': albumName,
          'coverUrl': 'https://cover.test/a1.jpg',
          'artistes': <Object?>['A'],
          'songs': <Object?>[
            <String, Object?>{'cid': 's1', 'name': 'Song One', 'artistes': <Object?>['A']},
            <String, Object?>{'cid': 's2', 'name': 'Song Two', 'artistes': <Object?>['A']},
          ],
        },
      });
    }
    if (uri.path == '/api/album/a2/detail') {
      return _json(<String, Object?>{
        'code': 0,
        'data': <String, Object?>{
          'name': 'Album Two',
          'coverUrl': 'https://cover.test/a2.jpg',
          'artistes': <Object?>['B'],
          'songs': <Object?>[
            <String, Object?>{'cid': 's3', 'name': 'Song Three', 'artistes': <Object?>['B']},
          ],
        },
      });
    }
    if (uri.path.endsWith('.lrc')) {
      if (lyricStatus != 200) {
        return const SirenHttpResult(statusCode: 500, bytes: <int>[]);
      }
      return _text(lyricText);
    }
    return const SirenHttpResult(statusCode: 404, bytes: <int>[]);
  }

  SirenRepository repository() {
    return SirenRepository(baseUri: Uri.parse('https://example.test'), get: handle);
  }
}

BasicController _controller(_Server server, _FakeAudio audio, {bool dark = true}) {
  return BasicController(audio: audio, repository: server.repository(), dark: dark);
}

void main() {
  group('boot / 曲库（Qt MusicSiren.cpp:36-88）', () {
    test('成功：状态文案逐字、phase=library、曲库可用', () async {
      final _Server server = _Server();
      final _FakeAudio audio = _FakeAudio();
      final BasicController controller = _controller(server, audio);
      addTearDown(controller.dispose);

      expect(controller.state.phase, BasicPhase.boot);
      await controller.boot();
      await _settle();

      expect(controller.state.phase, BasicPhase.library);
      expect(controller.state.loading, isFalse);
      expect(controller.state.catalogLoaded, isTrue);
      expect(controller.state.status, '已加载塞壬唱片曲库：3 首 / 2 张专辑');
      expect(controller.state.error, '');
      expect(controller.state.songs.length, 3);
      expect(controller.state.albums.length, 2);
      expect(controller.state.albums.first.songs.length, 2, reason: '曲库阶段按 albumCid 归组');
    });

    test('失败：读取失败文案 + error 上屏，retry 后恢复', () async {
      final _Server server = _Server()..songsStatus = 500;
      final _FakeAudio audio = _FakeAudio();
      final BasicController controller = _controller(server, audio);
      addTearDown(controller.dispose);

      await controller.boot();
      await _settle();

      expect(controller.state.phase, BasicPhase.library);
      expect(controller.state.loading, isFalse);
      expect(controller.state.catalogLoaded, isFalse);
      expect(controller.state.status, '塞壬唱片曲库读取失败：塞壬唱片请求失败（HTTP 500）');
      expect(controller.state.error, '塞壬唱片请求失败（HTTP 500）');
      expect(controller.state.songs, isEmpty);

      server.songsStatus = 200;
      await controller.retry();
      await _settle();

      expect(controller.state.catalogLoaded, isTrue);
      expect(controller.state.status, '已加载塞壬唱片曲库：3 首 / 2 张专辑');
      expect(controller.state.error, '');
    });

    test('空曲库：0 首 / 0 张专辑，空态不报错', () async {
      final _Server server = _Server()..emptyCatalog = true;
      final _FakeAudio audio = _FakeAudio();
      final BasicController controller = _controller(server, audio);
      addTearDown(controller.dispose);

      await controller.boot();
      await _settle();

      expect(controller.state.status, '已加载塞壬唱片曲库：0 首 / 0 张专辑');
      expect(controller.state.songs, isEmpty);
      expect(controller.state.albums, isEmpty);
      expect(controller.state.error, '');
    });

    test('未加载时搜索只提示"塞壬唱片曲库尚未加载"，不编造结果', () async {
      final _Server server = _Server();
      final _FakeAudio audio = _FakeAudio();
      final BasicController controller = _controller(server, audio);
      addTearDown(controller.dispose);

      await controller.setQuery('song');
      expect(controller.state.status, sirenLibraryUnloadedStatus);
      expect(controller.state.songs, isEmpty);
    });
  });

  group('setQuery（Qt MusicSiren.cpp:100-124 / :181-183）', () {
    test('命中数 = 可见歌曲 + 可见专辑；无命中给"没有匹配的音乐"；清空恢复曲库文案', () async {
      final _Server server = _Server();
      final _FakeAudio audio = _FakeAudio();
      final BasicController controller = _controller(server, audio);
      addTearDown(controller.dispose);
      await controller.boot();
      await _settle();

      await controller.setQuery('song one');
      expect(controller.state.query, 'song one');
      expect(controller.state.songs.length, 1);
      expect(controller.state.albums, isEmpty);
      expect(controller.state.status, '找到 1 条结果');

      await controller.setQuery('album');
      // Qt/src/MusicSiren.cpp:110-116 的曲目匹配是 title/album/artist 三字段 contains；
      // 假曲库的 a2 名字是 'Album Two'，也含 album，所以三首都命中（不是两首）。
      expect(controller.state.songs.length, 3, reason: 'title/album/artist 三字段命中 s1/s2/s3');
      expect(controller.state.albums.length, 2, reason: '专辑名/艺人命中 a1/a2');
      expect(controller.state.status, '找到 5 条结果', reason: '3 首 + 2 张');

      await controller.setQuery('zzz');
      expect(controller.state.songs, isEmpty);
      expect(controller.state.albums, isEmpty);
      expect(controller.state.status, '没有匹配的音乐');

      await controller.setQuery('');
      // Qt MusicLibrary.cpp:441-455：清空关键词走的是"空/超长输入"早退，状态栏上屏
      // '请输入 1–100 字关键词'（maximum 对非 qq 是 100），不是曲库加载结果文案。
      expect(controller.state.status, '请输入 1\u2013100 字关键词');
      expect(controller.state.songs.length, 3);
    });
  });

  group('openAlbum（siren.mjs:298-307 / :414-439）', () {
    test('成功：phase=detail、文案"已打开：…"、曲目来自 detail', () async {
      final _Server server = _Server();
      final _FakeAudio audio = _FakeAudio();
      final BasicController controller = _controller(server, audio);
      addTearDown(controller.dispose);
      await controller.boot();
      await _settle();

      final SirenAlbum catalogAlbum = controller.state.albums.firstWhere((SirenAlbum album) => album.id == 'a1');
      await controller.openAlbum(catalogAlbum);
      await _settle();

      expect(controller.state.phase, BasicPhase.detail);
      expect(controller.state.loading, isFalse);
      expect(controller.state.album?.id, 'a1');
      expect(controller.state.album?.name, 'Album One');
      expect(controller.state.album?.songCount, 2);
      expect(controller.state.songs.map((SirenSong song) => song.id).toList(), <String>['s1', 's2']);
      expect(controller.state.status, '已打开：Album One');
    });

    test('失败："读取失败：" + 真实错误，phase 仍是 detail 便于重试', () async {
      final _Server server = _Server();
      final _FakeAudio audio = _FakeAudio();
      final BasicController controller = _controller(server, audio);
      addTearDown(controller.dispose);
      await controller.boot();
      await _settle();

      server.albumDetailStatus = 500;
      final SirenAlbum catalogAlbum = controller.state.albums.firstWhere((SirenAlbum album) => album.id == 'a1');
      await controller.openAlbum(catalogAlbum);
      await _settle();

      expect(controller.state.loading, isFalse);
      expect(controller.state.error, '塞壬唱片返回 500：服务异常');
      expect(controller.state.status, '读取失败：塞壬唱片返回 500：服务异常');
      expect(controller.state.phase, BasicPhase.detail);
    });
  });

  group('openSong / 播放（siren.mjs:482-495；MusicPlayer.cpp:289/:429）', () {
    test('选曲：队列来自专辑详情、fresh 直链、prepare→play→playbackStarted', () async {
      final _Server server = _Server();
      final _FakeAudio audio = _FakeAudio();
      final BasicController controller = _controller(server, audio);
      addTearDown(controller.dispose);
      await controller.boot();
      await _settle();
      await controller.openAlbum(controller.state.albums.firstWhere((SirenAlbum album) => album.id == 'a1'));
      await _settle();

      final SirenSong song = controller.state.songs.firstWhere((SirenSong item) => item.id == 's2');
      await controller.openSong(song);
      await _settle();

      expect(controller.state.phase, BasicPhase.detail);
      expect(controller.state.song?.id, 's2');
      expect(controller.state.queue.map((SirenSong item) => item.id).toList(), <String>['s1', 's2']);
      expect(controller.state.queueIndex, 1);
      expect(controller.state.song?.sourceUrl, 'https://file.test/s2.flac',
          reason: 'sourceUrl 由播放前的 fresh /api/song/s2 提供，不是曲库缓存');
      expect(audio.calls, contains('prepare:https://file.test/s2.flac:1'));
      expect(audio.calls, contains('play:1'));
      expect(controller.state.playerStatus, '正在播放：Song Two');
      expect(controller.state.playing, isFalse, reason: 'playing 只来自 native 回报');

      audio.emit(const BasicAudioState(playing: true, positionMs: 0, durationMs: 10000, generation: 1));
      controller.pumpForTest(0.2);
      expect(controller.state.playing, isTrue);
    });

    test('上游无直链：播放失败文案就是 sirenNoSourceMessage，且不调 prepare', () async {
      final _Server server = _Server()..sourceFor = ((String id) => '');
      final _FakeAudio audio = _FakeAudio();
      final BasicController controller = _controller(server, audio);
      addTearDown(controller.dispose);
      await controller.boot();
      await _settle();

      await controller.openSong(controller.state.songs.first);
      await _settle();

      expect(controller.state.playbackError, sirenNoSourceMessage);
      expect(controller.state.playerStatus, sirenNoSourceMessage);
      expect(audio.calls.where((String call) => call.startsWith('prepare:')), isEmpty);
    });

    test('进度只认 native：连拍多次 pump 不产生 position；native 回报后原样上屏', () async {
      final _Server server = _Server();
      final _FakeAudio audio = _FakeAudio();
      final BasicController controller = _controller(server, audio);
      addTearDown(controller.dispose);
      await controller.boot();
      await _settle();
      await controller.openSong(controller.state.songs.first);
      await _settle();

      for (int i = 1; i <= 5; i += 1) {
        controller.pumpForTest(0.1 * i);
      }
      expect(controller.state.positionMs, 0, reason: '没有 native 回报就没有进度');
      expect(controller.state.progressFraction, 0);

      audio.emit(const BasicAudioState(
        playing: true,
        positionMs: 1200,
        durationMs: 10000,
        generation: 1,
      ));
      controller.pumpForTest(0.6);
      expect(controller.state.positionMs, 1200);
      expect(controller.state.durationMs, 10000);
      expect(controller.state.progressFraction, closeTo(0.12, 0.0001));
    });
  });

  group('歌词（lyrics_controller.dart:197-268；Qt LyricsController.cpp:281）', () {
    test('歌词就绪后 index 随 native position 变化', () async {
      final _Server server = _Server();
      final _FakeAudio audio = _FakeAudio();
      final BasicController controller = _controller(server, audio);
      addTearDown(controller.dispose);
      await controller.boot();
      await _settle();
      await controller.openSong(controller.state.songs.firstWhere((SirenSong item) => item.id == 's1'));
      await _settle();

      expect(controller.state.lyricStatus, 'ready');
      expect(controller.state.lyrics.length, 3);
      expect(controller.state.lyricIndex, 0, reason: 'position 0 命中第一行');

      audio.emit(const BasicAudioState(playing: true, positionMs: 1500, durationMs: 10000, generation: 1));
      controller.pumpForTest(0.2);
      expect(controller.state.positionMs, 1500);
      expect(controller.state.lyricIndex, 1);

      audio.emit(const BasicAudioState(playing: true, positionMs: 6000, durationMs: 10000, generation: 1));
      controller.pumpForTest(0.3);
      expect(controller.state.lyricIndex, 2);

      audio.emit(const BasicAudioState(playing: true, positionMs: 9000, durationMs: 10000, generation: 1));
      controller.pumpForTest(0.4);
      expect(controller.state.lyricIndex, 2, reason: '最后一行保持到结束');
    });

    test('seekToFraction：下发 seek + 立即重算 index，但 position 仍等 native 回报', () async {
      final _Server server = _Server();
      final _FakeAudio audio = _FakeAudio();
      final BasicController controller = _controller(server, audio);
      addTearDown(controller.dispose);
      await controller.boot();
      await _settle();
      await controller.openSong(controller.state.songs.firstWhere((SirenSong item) => item.id == 's1'));
      await _settle();

      audio.emit(const BasicAudioState(playing: true, positionMs: 0, durationMs: 10000, generation: 1));
      controller.pumpForTest(0.2);
      expect(controller.state.lyricIndex, 0);

      await controller.seekToFraction(0.5);

      expect(audio.calls, contains('seek:5000:1'), reason: '比例 × native 时长 = 5000ms');
      expect(controller.state.lyricIndex, 2, reason: 'seek 后立即按目标位置重算');
      expect(controller.state.positionMs, 0, reason: '本地绝不先把 position 改成 5000');

      audio.emit(const BasicAudioState(playing: true, positionMs: 5000, durationMs: 10000, generation: 1));
      controller.pumpForTest(0.3);
      expect(controller.state.positionMs, 5000);
    });

    test('歌词资源 500 → lyricStatus=empty，但 message 是真实错误而不是"暂无歌词"', () async {
      final _Server server = _Server()..lyricStatus = 500;
      final _FakeAudio audio = _FakeAudio();
      final BasicController controller = _controller(server, audio);
      addTearDown(controller.dispose);
      await controller.boot();
      await _settle();
      await controller.openSong(controller.state.songs.first);
      await _settle();

      expect(controller.state.lyricStatus, 'empty');
      expect(controller.state.lyricMessage, '塞壬唱片资源请求失败（HTTP 500）');
      expect(controller.state.lyrics, isEmpty);
    });

    test('没有歌词地址 → empty + "暂无歌词"', () async {
      final _Server server = _Server()..lyricFor = ((String id) => '');
      final _FakeAudio audio = _FakeAudio();
      final BasicController controller = _controller(server, audio);
      addTearDown(controller.dispose);
      await controller.boot();
      await _settle();
      await controller.openSong(controller.state.songs.first);
      await _settle();

      expect(controller.state.lyricStatus, 'empty');
      expect(controller.state.lyricMessage, sirenEmptyLyricsMessage);
      expect(controller.state.lyrics, isEmpty);
    });

    test('无时间轴文本 → plain（"此歌词没有时间信息"由域控制器给）', () async {
      final _Server server = _Server()..lyricText = '纯文本歌词';
      final _FakeAudio audio = _FakeAudio();
      final BasicController controller = _controller(server, audio);
      addTearDown(controller.dispose);
      await controller.boot();
      await _settle();
      await controller.openSong(controller.state.songs.first);
      await _settle();

      expect(controller.state.lyricStatus, 'plain');
      expect(controller.state.lyrics, isEmpty);
      expect(controller.state.lyricIndex, -1);
    });
  });

  group('导航（唯一 authority）', () {
    test('openLyrics 需要有当前曲；closeLyrics 回到 detail；back 回 library 但保留播放曲', () async {
      final _Server server = _Server();
      final _FakeAudio audio = _FakeAudio();
      final BasicController controller = _controller(server, audio);
      addTearDown(controller.dispose);
      await controller.boot();
      await _settle();

      // 首屏默认选中第一行（Qt 的 current 一进库就有一条；封面/唱片需要它），
      // 所以"没有当前曲目"要用真实的空列来构造：← 到「我的歌单」列（没有本地歌单）。
      await controller.navigateColumn(-1);
      expect(controller.state.song, isNull, reason: '空列清掉选中身份');
      await controller.openLyrics();
      expect(controller.state.phase, BasicPhase.library, reason: '没有当前曲目不允许进歌词页');

      // 回到「全部歌曲」列继续原来的断言（列 3 有 3 首真实曲目）。
      await controller.navigateColumn(1);
      await controller.openSong(controller.state.songs.first);
      await _settle();
      expect(controller.state.phase, BasicPhase.detail);

      await controller.openLyrics();
      expect(controller.state.phase, BasicPhase.lyrics);

      await controller.closeLyrics();
      expect(controller.state.phase, BasicPhase.detail);

      await controller.openLyrics();
      await controller.back();
      expect(controller.state.phase, BasicPhase.detail, reason: 'back 在歌词页等同 closeLyrics');

      await controller.back();
      expect(controller.state.phase, BasicPhase.library);
      expect(controller.state.album, isNull, reason: '专辑详情被关闭');
      expect(controller.state.song?.id, 's1', reason: '正在播放的歌不因返回而丢失');
    });
  });

  group('传输控制（MusicPlayer 状态机）', () {
    Future<BasicController> started(_Server server, _FakeAudio audio) async {
      final BasicController controller = _controller(server, audio);
      await controller.boot();
      await _settle();
      await controller.openSong(controller.state.songs.firstWhere((SirenSong item) => item.id == 's1'));
      await _settle();
      audio.emit(const BasicAudioState(playing: true, positionMs: 0, durationMs: 10000, generation: 1));
      controller.pumpForTest(0.2);
      return controller;
    }

    test('togglePlay 在播放中下发 pause，在暂停时下发 play', () async {
      final _Server server = _Server();
      final _FakeAudio audio = _FakeAudio();
      final BasicController controller = await started(server, audio);
      addTearDown(controller.dispose);
      audio.clearCalls();

      await controller.togglePlay();
      expect(audio.calls, contains('pause:1'));

      audio.emit(const BasicAudioState(playing: false, positionMs: 0, durationMs: 10000, generation: 1));
      controller.pumpForTest(0.3);
      await controller.togglePlay();
      expect(audio.calls, contains('play:1'));
    });

    test('next/previous 推进队列并重新 fresh 解析音源', () async {
      final _Server server = _Server();
      final _FakeAudio audio = _FakeAudio();
      final BasicController controller = await started(server, audio);
      addTearDown(controller.dispose);

      await controller.next();
      await _settle();
      expect(controller.state.queueIndex, 1);
      // 选中（state.song）与播放身份（state.playingTrack）是两件事：Qt 的
      // MusicPlayer::next 只推进队列并重播，不改 MusicLibrary 的 current/选中；
      // 换曲要走 scene→selectionRequested→observe 才会动选中。
      expect(controller.state.playingTrack?.id, 's2');
      expect(controller.state.song?.id, 's1', reason: 'next 不移动浏览选中');
      expect(audio.calls, contains('prepare:https://file.test/s2.flac:2'));

      await controller.previous();
      await _settle();
      expect(controller.state.queueIndex, 0);
      expect(controller.state.playingTrack?.id, 's1');
    });

    test('dispose 后不再响应 native 状态，也不 dispose B 的音频端口', () async {
      final _Server server = _Server();
      final _FakeAudio audio = _FakeAudio();
      final BasicController controller = await started(server, audio);
      controller.dispose();

      expect(() {
        audio.emit(const BasicAudioState(playing: true, positionMs: 3000, durationMs: 10000, generation: 1));
      }, returnsNormally);
      expect(audio.calls, isNot(contains('dispose')), reason: 'BasicAudioPort 由组合根 lane D 持有');
    });

    test('dark 跟随构造参数（基础版不做主题切换）', () async {
      final _Server server = _Server();
      final _FakeAudio audio = _FakeAudio();
      final BasicController controller = _controller(server, audio, dark: false);
      addTearDown(controller.dispose);
      await controller.boot();
      expect(controller.state.dark, isFalse);
    });
  });

  group('世代丢弃（Qt/src/MusicApi.cpp:98-100：valid 失败不进 callback）', () {
    test('迟到的曲库响应整份丢弃，且 loading 保持（Qt MusicSiren.cpp:52-56）', () async {
      final _Server server = _Server();
      final _FakeAudio audio = _FakeAudio();
      final List<Completer<SirenHttpResult>> songGates = <Completer<SirenHttpResult>>[];
      final List<Completer<SirenHttpResult>> albumGates = <Completer<SirenHttpResult>>[];
      server.override = (Uri uri) {
        final Completer<SirenHttpResult> gate = Completer<SirenHttpResult>();
        if (uri.path == '/api/songs') {
          songGates.add(gate);
        } else {
          albumGates.add(gate);
        }
        return gate.future;
      };
      final BasicController controller = _controller(server, audio);
      addTearDown(controller.dispose);

      unawaited(controller.boot());
      await _settle();
      expect(songGates.length, 1);
      expect(albumGates.length, 1);

      // 第二次加载（retry）让第一代过期。
      unawaited(controller.retry());
      await _settle();
      expect(songGates.length, 2);
      expect(albumGates.length, 2);

      songGates[0].complete(_json(<String, Object?>{'code': 0, 'data': <Object?>[
        <String, Object?>{'cid': 'old', 'name': 'Old', 'albumCid': 'a1', 'artists': <Object?>['A']},
      ]}));
      albumGates[0].complete(_json(<String, Object?>{'code': 0, 'data': <Object?>[
        <String, Object?>{'cid': 'a1', 'name': 'Old Album', 'artistes': <Object?>['A']},
      ]}));
      await _settle();

      expect(controller.state.songs, isEmpty, reason: '迟到的一代不许写入状态');
      expect(controller.state.loading, isTrue, reason: 'Qt 的 valid 失败分支不复位 loading');

      songGates[1].complete(_json(<String, Object?>{'code': 0, 'data': <Object?>[
        <String, Object?>{'cid': 's1', 'name': 'Song One', 'albumCid': 'a1', 'artists': <Object?>['A']},
      ]}));
      albumGates[1].complete(_json(<String, Object?>{'code': 0, 'data': <Object?>[
        <String, Object?>{'cid': 'a1', 'name': 'Album One', 'artistes': <Object?>['A']},
      ]}));
      await _settle();

      expect(controller.state.songs.single.id, 's1');
      expect(controller.state.loading, isFalse);
      expect(controller.state.status, '已加载塞壬唱片曲库：1 首 / 1 张专辑');
    });

    test('迟到的专辑详情不覆盖后一次打开的结果', () async {
      final _Server server = _Server();
      final _FakeAudio audio = _FakeAudio();
      final BasicController controller = _controller(server, audio);
      addTearDown(controller.dispose);
      await controller.boot();
      await _settle();

      final List<Completer<SirenHttpResult>> gates = <Completer<SirenHttpResult>>[];
      server.override = (Uri uri) {
        final Completer<SirenHttpResult> gate = Completer<SirenHttpResult>();
        gates.add(gate);
        return gate.future;
      };

      final SirenAlbum a1 = controller.state.albums.firstWhere((SirenAlbum album) => album.id == 'a1');
      final SirenAlbum a2 = controller.state.albums.firstWhere((SirenAlbum album) => album.id == 'a2');

      unawaited(controller.openAlbum(a1));
      await _settle();
      unawaited(controller.openAlbum(a2));
      await _settle();
      expect(gates.length, 2);

      gates[0].complete(_json(<String, Object?>{'code': 0, 'data': <String, Object?>{
        'name': 'Album One (late)',
        'artistes': <Object?>['A'],
        'songs': <Object?>[],
      }}));
      await _settle();

      expect(controller.state.album?.id, 'a2', reason: '迟到的 a1 详情不许抢回页面');
      expect(controller.state.loading, isTrue);

      gates[1].complete(_json(<String, Object?>{'code': 0, 'data': <String, Object?>{
        'name': 'Album Two',
        'artistes': <Object?>['B'],
        'songs': <Object?>[
          <String, Object?>{'cid': 's3', 'name': 'Song Three', 'artistes': <Object?>['B']},
        ],
      }}));
      await _settle();

      expect(controller.state.album?.id, 'a2');
      expect(controller.state.album?.name, 'Album Two');
      expect(controller.state.songs.single.id, 's3');
      expect(controller.state.loading, isFalse);
    });
  });

  // Qt/src/MusicSiren.cpp:193-246（openSirenAllSongs）、MusicDirectory.cpp:302-319
  // （selectDirectory 先写 index 再 choose）、:417-452（leaveDirectory 返回父目录）。
  group('虚拟目录（全部歌曲）', () {
    test('openAllSirenSongs：只选中第一首，不 prepare、不 play、不动队列', () async {
      final _Server server = _Server();
      final _FakeAudio audio = _FakeAudio();
      final BasicController controller = _controller(server, audio);
      addTearDown(controller.dispose);
      await controller.boot();
      await _settle();
      audio.clearCalls();

      await controller.openAllSirenSongs();

      expect(controller.state.phase, BasicPhase.library);
      expect(controller.state.status, '已打开：全部歌曲');
      expect(controller.state.directory?.id, 'siren-all');
      expect(controller.state.directory?.songs.length, 3);
      expect(controller.state.directory?.index, 0);
      expect(controller.state.song?.id, 's1');
      expect(controller.state.albums, isEmpty);
      expect(controller.state.queue, isEmpty);
      expect(controller.state.playing, isFalse);
      expect(
        audio.calls,
        isEmpty,
        reason: 'Qt 这里只 choose：play() 只在用户按播放时才 replaceQueue（MusicLibrary.cpp:943-957）',
      );
    });

    test('目录内选曲：队列取目录顺序，directory.index 跟着选中行', () async {
      final _Server server = _Server();
      final _FakeAudio audio = _FakeAudio();
      final BasicController controller = _controller(server, audio);
      addTearDown(controller.dispose);
      await controller.boot();
      await _settle();
      await controller.openAllSirenSongs();
      audio.clearCalls();

      await controller.openSong(controller.state.songs[1]);
      await _settle();

      expect(controller.state.phase, BasicPhase.detail);
      expect(
        controller.state.queue.map((SirenSong song) => song.id).toList(),
        <String>['s1', 's2', 's3'],
        reason: 'Qt directorySource()：目录内播放队列就是目录曲目（MusicLibrary.cpp:975-984）',
      );
      expect(controller.state.queueIndex, 1);
      expect(controller.state.directory?.index, 1, reason: 'selectDirectory 先写 index 再 choose');
      expect(audio.calls, contains('prepare:https://file.test/s2.flac:1'));
      expect(audio.calls, contains('play:1'));
      expect(controller.state.playerStatus, '正在播放：Song Two');
      expect(controller.state.playing, isFalse, reason: 'playing 只认 native 读数');
    });

    test('目录内返回上一级：回资料库根，队列不中断', () async {
      final _Server server = _Server();
      final _FakeAudio audio = _FakeAudio();
      final BasicController controller = _controller(server, audio);
      addTearDown(controller.dispose);
      await controller.boot();
      await _settle();
      await controller.openAllSirenSongs();

      await controller.back();

      expect(controller.state.directory, isNull);
      expect(controller.state.phase, BasicPhase.library);
      expect(controller.state.status, '已返回：塞壬唱片');
      expect(controller.state.songs.length, 3);
      // Qt/src/MusicSiren.cpp:225 `next->parentItem = current;` 与 MusicDirectory.cpp:431-435
      // 的 `current = details.value(key, folder->parentItem)`：返回资料库根时 current 被
      // 恢复成**打开目录那一刻**的选中身份。首屏已默认选中第一行，所以 parentItem 不是空
      // 对象，恢复回来就是 s1（不是"清空"）。它与播放队列无关：队列/播放不因返回而变。
      expect(controller.state.song?.id, 's1', reason: 'parentItem = 打开时的 current');
      expect(controller.state.selection?.id, 's1');
    });

    test('目录内搜索离开目录（Qt/src/MusicSiren.cpp:184-188）', () async {
      final _Server server = _Server();
      final _FakeAudio audio = _FakeAudio();
      final BasicController controller = _controller(server, audio);
      addTearDown(controller.dispose);
      await controller.boot();
      await _settle();
      await controller.openAllSirenSongs();

      await controller.setQuery('Song Two');

      expect(controller.state.directory, isNull);
      expect(controller.state.songs.single.id, 's2');
      expect(controller.state.status, '找到 1 条结果');
    });

    test('未加载曲库时不造目录（Qt :194-197）', () async {
      final _Server server = _Server();
      final _FakeAudio audio = _FakeAudio();
      final BasicController controller = _controller(server, audio);
      addTearDown(controller.dispose);

      await controller.openAllSirenSongs();

      expect(controller.state.directory, isNull);
      expect(controller.state.songs, isEmpty);
      expect(controller.state.status, sirenLibraryUnloadedStatus);
      expect(audio.calls, isEmpty);
    });
  });

  // Qt/src/MusicLibrary.cpp:843-869 `selectResult(index, lane, open=true)`：
  //   mode = open && kind == "song" ? "detail" : "archive";
  //   if (open && current.kind != "song") enterDirectory(current);
  // 即「点专辑行 = 换列（进该专辑目录）」，只有曲目行才进详情抽唱片。
  // 用户 2026-11-19 报：进入专辑应换列而不是抽出唱片。
  group('进入专辑 = 换列（不抽唱片）', () {
    test('enterAlbumColumn：留在 library 相位，directory 就是这张专辑', () async {
      final _Server server = _Server();
      final _FakeAudio audio = _FakeAudio();
      final BasicController controller = _controller(server, audio);
      addTearDown(controller.dispose);
      await controller.boot();
      await _settle();
      audio.clearCalls();

      await controller.enterAlbumColumn(controller.state.albums.first);
      await _settle();

      expect(controller.state.phase, BasicPhase.library, reason: '不推进详情相位');
      expect(controller.state.album, isNull, reason: '没有抽唱片，就没有「当前专辑详情」');
      expect(controller.state.directory?.kind, 'album');
      expect(controller.state.directory?.id, 'a1');
      expect(controller.state.directory?.title, 'Album One');
      expect(
        controller.state.directory?.songs.map((SirenSong song) => song.id).toList(),
        <String>['s1', 's2'],
        reason: '目录曲目来自 /api/album/a1/detail',
      );
      expect(controller.state.directory?.index, 0);
      expect(controller.state.song?.id, 's1', reason: '只选中第一首');
      expect(controller.state.queue, isEmpty, reason: '换列不 replaceQueue');
      expect(audio.calls, isEmpty, reason: '换列不出声（Qt 的 enterDirectory 不 play）');
    });

    test('单曲专辑：进列后仍是曲库相位，不自动打开详情', () async {
      final _Server server = _Server();
      final _FakeAudio audio = _FakeAudio();
      final BasicController controller = _controller(server, audio);
      addTearDown(controller.dispose);
      await controller.boot();
      await _settle();
      audio.clearCalls();

      final SirenAlbum single =
          controller.state.albums.firstWhere((SirenAlbum album) => album.id == 'a2');
      await controller.enterAlbumColumn(single);
      await _settle();

      expect(controller.state.phase, BasicPhase.library);
      expect(controller.state.directory?.songs.length, 1);
      expect(controller.state.song?.id, 's3');
      expect(
        controller.state.phase == BasicPhase.detail,
        isFalse,
        reason: '单曲专辑也必须停在列上——详情只由点曲目行的 open 打开',
      );
      expect(audio.calls, isEmpty);
    });

    test('enterAlbumColumn(play: true)：进列后从第一首起播，队列是专辑曲目', () async {
      final _Server server = _Server();
      final _FakeAudio audio = _FakeAudio();
      final BasicController controller = _controller(server, audio);
      addTearDown(controller.dispose);
      await controller.boot();
      await _settle();
      audio.clearCalls();

      await controller.enterAlbumColumn(
        controller.state.albums.firstWhere((SirenAlbum album) => album.id == 'a2'),
        play: true,
      );
      await _settle();

      expect(controller.state.queue.map((SirenSong song) => song.id).toList(), <String>['s3']);
      expect(audio.calls, contains('prepare:https://file.test/s3.flac:1'));
      expect(audio.calls, contains('play:1'));
    });
  });
}
