// FINAL-ACCEPTANCE-155 · 封面迟到结果的收口回归（FSR 组已按 m03406 暂缓移出本阶段）。
//
// 本文件守的是一条**真实链路**，不是注释：
//
//  通知封面的迟到结果：同一 (id, url) 的旧闭包回来时（成功**或异常**）都不能改写
//     当前身份的封面；封面变空要立刻上报空；失败重试有界；缓存自己在文件系统上
//     出错不能把"已经落盘"的结论改成"没有"。
//
// 说明：f669f56 里的 FSR 档位/锐化桥（BasicSceneSettings.fsrQuality/fsrSharpness →
// 场景快照 → Qt qputenv）连同它的断言组一起暂缓（用户 m03406）。FSR 的持久化契约
// （panel/fsr-quality|fsr-sharpness）仍在 basic_settings.dart 的 antiAliasing 细项里，
// 属既有范围，本阶段既不新增 UI 也不做当场生效。
//
// 真机上的通知可见性仍由设备验收负责，不能拿这里的 pass 当 device PASS。

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:rhine_music_database/basic/basic_art_cache.dart';
import 'package:rhine_music_database/basic/basic_models.dart';
import 'package:rhine_music_database/basic/platform_playback.dart';
import 'package:rhine_music_database/basic/siren_controller.dart';
import 'package:rhine_music_database/basic/siren_repository.dart';
import 'package:rhine_music_database/platform/media_session.dart';

/// 让排队的微任务/零延迟 Future 走完（沿用 test/basic/siren_controller_test.dart）。
Future<void> _settle() async {
  for (int i = 0; i < 16; i += 1) {
    await Future<void>.delayed(Duration.zero);
  }
}

SirenHttpResult _json(Object? body, {int statusCode = 200}) {
  return SirenHttpResult(
      statusCode: statusCode, bytes: utf8.encode(jsonEncode(body)));
}

SirenHttpResult _text(String body, {int statusCode = 200}) {
  return SirenHttpResult(statusCode: statusCode, bytes: utf8.encode(body));
}

// ---------------------------------------------------------------------------
// 端口替身（与 test/basic/user_scope_152_test.dart 同一套形状，这里只留用到的）
// ---------------------------------------------------------------------------

class _FakeAudio implements BasicAudioPort {
  BasicAudioState _state = const BasicAudioState();
  final List<String> calls = <String>[];
  final List<void Function(BasicAudioState)> _listeners =
      <void Function(BasicAudioState)>[];

  BasicAudioState get state => _state;

  void addListener(void Function(BasicAudioState) listener) {
    _listeners.add(listener);
  }

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

  Future<void> prepare(String url, {required int generation}) async {
    calls.add('prepare:$url:$generation');
    emit(BasicAudioState(buffering: true, generation: generation));
  }

  Future<void> play({required int generation}) async {
    calls.add('play:$generation');
  }

  Future<void> pause({required int generation}) async {
    calls.add('pause:$generation');
  }

  Future<void> seekTo(double positionMs, {required int generation}) async {
    calls.add('seek:${positionMs.toStringAsFixed(0)}:$generation');
  }

  Future<void> stop() async {
    calls.add('stop');
  }

  Future<void> dispose() async {
    calls.add('dispose');
  }
}

class _FakeMediaPort implements MediaSessionPort {
  _FakeMediaPort({this.directory});

  final String? directory;
  final List<MediaSessionState> updates = <MediaSessionState>[];
  int stops = 0;
  int disposes = 0;
  int ensureStarts = 0;

  Future<bool> ensureStarted() async {
    ensureStarts += 1;
    return true;
  }

  Future<void> update(MediaSessionState state) async {
    updates.add(state);
  }

  Future<void> stop() async {
    stops += 1;
  }

  Stream<String> get actions => const Stream<String>.empty();

  Future<String?> cacheDirectory() async => directory;

  Future<void> dispose() async {
    disposes += 1;
  }
}

class _FakeHeaders implements HttpHeaders {
  final Map<String, String> values = <String, String>{};

  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {
    values[name] = '$value';
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _FakeRequest implements HttpClientRequest {
  _FakeRequest(this.uri, this._gate);

  final Completer<List<int>> _gate;

  @override
  final Uri uri;

  @override
  final HttpHeaders headers = _FakeHeaders();

  @override
  Future<HttpClientResponse> close() async => _FakeResponse(await _gate.future);

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _FakeResponse implements HttpClientResponse {
  _FakeResponse(this._bytes);

  final List<int> _bytes;

  @override
  int get statusCode => 200;

  @override
  int get contentLength => _bytes.length;

  @override
  StreamSubscription<List<int>> listen(void Function(List<int>)? onData,
      {Function? onError, void Function()? onDone, bool? cancelOnError}) {
    return Stream<List<int>>.value(_bytes).listen(onData,
        onError: onError, onDone: onDone, cancelOnError: cancelOnError);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _FakeHttpClient implements HttpClient {
  final Map<String, List<Completer<List<int>>>> gates =
      <String, List<Completer<List<int>>>>{};
  final List<String> requested = <String>[];

  List<Completer<List<int>>> gatesFor(String url) =>
      gates.putIfAbsent(url, () => <Completer<List<int>>>[]);

  @override
  Duration? connectionTimeout;

  @override
  Future<HttpClientRequest> getUrl(Uri url) async {
    final String key = url.toString();
    requested.add(key);
    final Completer<List<int>> gate = Completer<List<int>>();
    gatesFor(key).add(gate);
    return _FakeRequest(url, gate);
  }

  @override
  void close({bool force = false}) {}

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

/// 假塞壬站点：只回真协议形状（code:0 + data），不触网。
class _Server {
  final Map<String, String> albumCovers = <String, String>{
    'a1': 'https://cover.test/a1.jpg',
    'a2': 'https://cover.test/a2.jpg',
  };

  Future<SirenHttpResult> handle(Uri uri) async {
    if (uri.path == '/api/songs') {
      return _json(<String, Object?>{
        'code': 0,
        'data': <Object?>[
          <String, Object?>{
            'cid': 's1',
            'name': 'Song One',
            'albumCid': 'a1',
            'artists': <Object?>['A'],
          },
          <String, Object?>{
            'cid': 's2',
            'name': 'Song Two',
            'albumCid': 'a2',
            'artists': <Object?>['B'],
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
            'name': 'Album One',
            'artistes': <Object?>['A'],
            'coverUrl': albumCovers['a1'],
          },
          <String, Object?>{
            'cid': 'a2',
            'name': 'Album Two',
            'artistes': <Object?>['B'],
            'coverUrl': albumCovers['a2'],
          },
        ],
      });
    }
    if (uri.path.startsWith('/api/song/')) {
      final String id = uri.path.substring('/api/song/'.length);
      final String name = <String, String>{'s1': 'Song One', 's2': 'Song Two'}[id] ?? id;
      return _json(<String, Object?>{
        'code': 0,
        'data': <String, Object?>{
          'name': name,
          'sourceUrl': 'https://file.test/$id.flac',
          'lyricUrl': 'https://file.test/$id.lrc',
        },
      });
    }
    if (uri.path.endsWith('.lrc')) {
      return _text('[00:00.00]line0\n[00:10.00]line1');
    }
    return const SirenHttpResult(statusCode: 404, bytes: <int>[]);
  }

  SirenRepository repository() {
    return SirenRepository(baseUri: Uri.parse('https://example.test'), get: handle);
  }
}

/// 一个"承诺不抛、但其实会抛"的缓存：用来证明控制器里那条 catch 有身份/代次护栏。
///
/// 真实的 [BasicArtCache] 已经把文件系统异常收敛干净（这也是本文件另一组的断言），
/// 所以这条迟到异常只能用替身造出来——它模拟的是"任何一处上游最终还是抛了"。
class _GatedThrowingCache extends BasicArtCache {
  _GatedThrowingCache({required super.directory, super.client});

  final Map<String, Completer<void>> gates = <String, Completer<void>>{};

  @override
  Future<String?> localPath(String url) async {
    final Completer<void>? gate = gates[url];
    if (gate != null) {
      await gate.future;
      throw const FileSystemException('迟到的封面异常（替身造的）');
    }
    return super.localPath(url);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('通知封面：迟到结果/异常与有界重试', () {
    late Directory tempDir;
    late _FakeHttpClient client;
    late _FakeMediaPort port;
    late _FakeAudio audio;
    late _Server server;
    late BasicArtCache cache;
    late BasicController controller;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('final_acceptance_155');
      client = _FakeHttpClient();
      port = _FakeMediaPort(directory: tempDir.path);
      audio = _FakeAudio();
      server = _Server();
      cache = BasicArtCache(
        directory: () async => tempDir.path,
        client: client,
      );
      controller = BasicController(
        audio: audio,
        repository: server.repository(),
        mediaSessionPort: port,
        artCache: cache,
      );
      addTearDown(() async {
        controller.dispose();
        await _settle();
        if (tempDir.existsSync()) {
          tempDir.deleteSync(recursive: true);
        }
      });
      await controller.boot();
      await _settle();
    });

    SirenSong songOf(String title) =>
        controller.state.songs.firstWhere((SirenSong song) => song.title == title);

    Future<void> playAndEmit(SirenSong song) async {
      await controller.openSong(song, play: true);
      await _settle();
      audio.emit(BasicAudioState(
          playing: true, positionMs: 0, durationMs: 20000, generation: 1));
      await _settle();
    }

    Future<Completer<List<int>>> gateFor(String url, [int nth = 0]) async {
      for (int i = 0; i < 200; i += 1) {
        final List<Completer<List<int>>> list = client.gatesFor(url);
        if (list.length > nth) {
          return list[nth];
        }
        await Future<void>.delayed(Duration.zero);
      }
      throw StateError('封面请求没有发出：' +
          url +
          '（已请求 ' +
          client.requested.join(', ') +
          '）');
    }

    Future<MediaSessionState> waitForCover(int fromIndex,
        [_FakeMediaPort? target]) async {
      final _FakeMediaPort sink = target ?? port;
      for (int i = 0; i < 400; i += 1) {
        for (final MediaSessionState state in sink.updates.skip(fromIndex)) {
          final String path = state.coverPath ?? '';
          if (path.isNotEmpty && File(path).existsSync()) {
            return state;
          }
        }
        await Future<void>.delayed(const Duration(milliseconds: 2));
      }
      throw StateError('没有等到带本地封面的上报');
    }

    test('同一 URL 并发只发一次请求（一个在飞拥有者）', () async {
      final String url = 'https://cover.test/a1.jpg';
      final Future<String?> first = cache.localPath(url);
      final Future<String?> second = cache.localPath(url);
      for (int i = 0; i < 200 && client.gatesFor(url).isEmpty; i += 1) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(client.requested.where((String r) => r == url).length, 1,
          reason: '滚动/重绘会短时间重复问同一张图：只能有一个在飞请求');
      client.gatesFor(url).first.complete(<int>[4, 5, 6]);
      expect(await first, await second);
      expect(await first, endsWith('.img'));

      // 落盘后再问同一个 URL：命中本地文件，不再发请求。
      final String? cachedPath = await cache.localPath(url);
      expect(cachedPath, await first);
      expect(client.requested.where((String r) => r == url).length, 1);
    });

    test('失败后有界重试：第二次真实请求，第三次不再发', () async {
      final SirenSong a = songOf('Song One');
      await playAndEmit(a);
      // 第一条请求还在飞（gate[0] 未完成）：此时再上报必须被在飞名额挡住。
      // 断言必须在完成 gate **之前**数请求：完成后任何一次真实上报都允许一次合法重试，
      // 数在之后就会把"合法重试"误判成"无限重试"，在全量并发跑时变成抖动断言。
      expect(client.requested.length, 1,
          reason: '同一 (id,url) 在飞时不允许重复建闭包');

      (await gateFor(a.cover, 0)).complete(<int>[]);
      await _settle();
      expect(client.requested.length, 1,
          reason: '失败本身不触发重试：只有下一次上报才允许再发一次');
      expect(port.updates.last.coverPath, '');

      // 再发布一次（同一身份、同一 URL、真实 audio 上报）：允许一次重试，且真的再发请求。
      audio.emit(BasicAudioState(
          playing: true, positionMs: 1000, durationMs: 20000, generation: 1));
      await _settle();
      expect(client.requested.length, 2);
      final Completer<List<int>> second = await gateFor(a.cover, 1);
      second.complete(<int>[]);
      await _settle();
      expect(port.updates.last.coverPath, '');

      // 第三次：额度用尽，不再建闭包，也不再发请求。
      audio.emit(BasicAudioState(
          playing: true, positionMs: 2000, durationMs: 20000, generation: 1));
      await _settle();
      expect(client.requested.length, 2,
          reason: '_artMaxAttempts 是硬上限，不能无限重试');
    });

    test('迟到的异常不会清掉已经落好的新封面', () async {
      // 换一个"承诺不抛却会抛"的缓存：只对 A 的 URL 迟到抛异常。
      final _GatedThrowingCache throwing = _GatedThrowingCache(
        directory: () async => tempDir.path,
        client: client,
      );
      final _FakeMediaPort port2 = _FakeMediaPort(directory: tempDir.path);
      final _FakeAudio audio2 = _FakeAudio();
      final BasicController controller2 = BasicController(
        audio: audio2,
        repository: server.repository(),
        mediaSessionPort: port2,
        artCache: throwing,
      );
      addTearDown(() async {
        controller2.dispose();
        await _settle();
      });
      await controller2.boot();
      await _settle();

      final SirenSong a =
          controller2.state.songs.firstWhere((SirenSong s) => s.title == 'Song One');
      final SirenSong b =
          controller2.state.songs.firstWhere((SirenSong s) => s.title == 'Song Two');

      // A：闸门挂住，稍后抛异常。
      final Completer<void> gate = Completer<void>();
      throwing.gates[a.cover] = gate;
      await controller2.openSong(a, play: true);
      await _settle();
      audio2.emit(BasicAudioState(
          playing: true, positionMs: 0, durationMs: 20000, generation: 0));
      await _settle();

      // B：真缓存路径，直接落盘成功（同一个 controller 里 B 的图必须在）。
      final int beforeB = port2.updates.length;
      await controller2.openSong(b, play: true);
      await _settle();
      audio2.emit(BasicAudioState(
          playing: true, positionMs: 0, durationMs: 20000, generation: 0));
      await _settle();
      (await gateFor(b.cover)).complete(<int>[7, 7, 7, 7]);
      final String coverB = (await waitForCover(beforeB, port2)).coverPath ?? '';
      expect(coverB, isNotEmpty);

      // 现在让 A 的旧闭包迟到抛异常：它不属于当前身份，绝不能清空 B。
      gate.complete();
      await _settle();
      expect(port2.updates.last.coverPath, coverB,
          reason: 'catch 里没有身份/代次护栏时，这一条会变成空封面');
      expect(port2.updates.last.title, 'Song Two');
      expect(File(coverB).existsSync(), isTrue);
    });

    test('缓存自己的文件系统抖动不会把"已落盘"改成"没有"', () async {
      // 目录在抓取过程中被整体删掉：_prune/读取必须自己收敛，不能把异常漏给调用方。
      final Directory dir =
          await Directory.systemTemp.createTemp('final_acceptance_155_fs');
      final _FakeHttpClient client2 = _FakeHttpClient();
      final BasicArtCache fragile = BasicArtCache(
        directory: () async => dir.path,
        client: client2,
      );
      addTearDown(() async {
        await fragile.close();
        if (dir.existsSync()) {
          dir.deleteSync(recursive: true);
        }
      });

      final String url = 'https://cover.test/fragile.jpg';
      final Future<String?> pending = fragile.localPath(url);
      for (int i = 0; i < 200 && client2.gatesFor(url).isEmpty; i += 1) {
        await Future<void>.delayed(Duration.zero);
      }
      // 目录先消失再回字节：落盘的 writeAsBytes 会失败，但 localPath 必须**返回 null**
      // 而不是抛出去（这是它对控制器的承诺）。
      dir.deleteSync(recursive: true);
      client2.gatesFor(url).first.complete(<int>[1, 2, 3]);
      final String? result = await pending;
      expect(result, isNull);
    });
  });
}
