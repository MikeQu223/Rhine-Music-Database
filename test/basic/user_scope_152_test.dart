// USER-SCOPE-152 · 设置 / 系统媒体 / 通知封面的接线回归。
//
// 守住三条接线：音质落到宿主偏好键、详情页自动播放只在 open + 偏好开启时触发、
// 通知封面先把远端 URL 落成私有目录里的真实文件。
// 通知可见性与前台服务存活只能设备验收，静态守卫不算 PASS。

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:rhine_music_database/basic/basic_art_cache.dart';
import 'package:rhine_music_database/basic/basic_models.dart';
import 'package:rhine_music_database/basic/basic_settings.dart';
import 'package:rhine_music_database/basic/basic_settings_runtime.dart';
import 'package:rhine_music_database/basic/basic_settings_store.dart';
import 'package:rhine_music_database/basic/platform_playback.dart';
import 'package:rhine_music_database/basic/siren_controller.dart';
import 'package:rhine_music_database/basic/siren_repository.dart';
import 'package:rhine_music_database/hud/modals/settings_modal.dart';
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

const BasicSettingsPackageInfo _androidPackage = BasicSettingsPackageInfo(
  packageName: 'rhine.music.database',
  versionName: '1.5.2',
  versionCode: 4152,
  debuggable: true,
);

SettingsPreferenceContext _settingsContext({String providerId = 'siren'}) =>
    SettingsPreferenceContext(
      capabilities: const PlatformCapabilities.android(),
      operatingSystem: SettingsOperatingSystem.android,
      providerId: providerId,
      musicEnabled: true,
      providerIsLocal: false,
    );

/// 真音频端口的替身：只记录调用 + 可手动 emit 真实读数（不伪造进度）。
class _FakeAudio implements BasicAudioPort {
  BasicAudioState _state = const BasicAudioState();
  final List<String> calls = <String>[];
  final List<void Function(BasicAudioState)> _listeners =
      <void Function(BasicAudioState)>[];

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

  @override
  Future<void> prepare(String url, {required int generation}) async {
    calls.add('prepare:$url:$generation');
    emit(BasicAudioState(buffering: true, generation: generation));
  }

  @override
  Future<void> play({required int generation}) async {
    calls.add('play:$generation');
  }

  @override
  Future<void> pause({required int generation}) async {
    calls.add('pause:$generation');
  }

  @override
  Future<void> seekTo(double positionMs, {required int generation}) async {
    calls.add('seek:${positionMs.toStringAsFixed(0)}:$generation');
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

/// 系统媒体控件端口的替身：记录每一次真实上报。
class _FakeMediaPort implements MediaSessionPort {
  _FakeMediaPort({this.directory});

  final String? directory;
  final List<MediaSessionState> updates = <MediaSessionState>[];
  int stops = 0;
  int disposes = 0;
  int ensureStarts = 0;

  @override
  Future<bool> ensureStarted() async {
    ensureStarts += 1;
    return true;
  }

  @override
  Future<void> update(MediaSessionState state) async {
    updates.add(state);
  }

  @override
  Future<void> stop() async {
    stops += 1;
  }

  @override
  Stream<String> get actions => const Stream<String>.empty();

  @override
  Future<String?> cacheDirectory() async => directory;

  @override
  Future<void> dispose() async {
    disposes += 1;
  }
}

/// 假塞壬站点：只回真协议形状（code:0 + data），不触网。歌的封面来自专辑表。
class _Server {
  final List<Uri> calls = <Uri>[];

  /// 专辑封面可换：用来造"同一身份换了封面 URL"这种真实可达的状态切换
  /// （详情覆盖曲库封面，lib/basic/siren_repository.dart albumDetail 的 albumCover）。
  final Map<String, String> albumCovers = <String, String>{
    'a1': 'https://cover.test/a1.jpg',
    'a2': 'https://cover.test/a2.jpg',
  };

  Future<SirenHttpResult> handle(Uri uri) async {
    calls.add(uri);
    if (uri.path == '/api/songs') {
      return _json(<String, Object?>{
        'code': 0,
        'data': <Object?>[
          <String, Object?>{
            'cid': 's1',
            'name': 'Song One',
            'albumCid': 'a1',
            'artists': <Object?>['A']
          },
          <String, Object?>{
            'cid': 's2',
            'name': 'Song Two',
            'albumCid': 'a2',
            'artists': <Object?>['B']
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
    if (uri.path.startsWith('/api/album/') && uri.path.endsWith('/detail')) {
      final String id = uri.path
          .substring('/api/album/'.length)
          .replaceAll('/detail', '');
      return _json(<String, Object?>{
        'code': 0,
        'data': <String, Object?>{
          'cid': id,
          'name': id == 'a1' ? 'Album One' : 'Album Two',
          'coverUrl': albumCovers[id],
          'artistes': <Object?>[id == 'a1' ? 'A' : 'B'],
          'songs': <Object?>[
            <String, Object?>{
              'cid': 's1',
              'name': 'Song One',
              'artistes': <Object?>['A'],
            },
          ],
        },
      });
    }
    if (uri.path.startsWith('/api/song/')) {
      final String id = uri.path.substring('/api/song/'.length);
      // 详情里的歌名必须和曲库一致：控制器会拿详情覆盖 _songById[id]
      // （lib/basic/siren_controller.dart:1615-1620），名字不一致的话
      // 通知/队列标题会在详情回来那一刻改名，测试就会在断言标题上假失败。
      final String name = <String, String>{'s1': 'Song One', 's2': 'Song Two'}[id] ?? 'Song $id';
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

// ---------------------------------------------------------------------------
// 封面：最小 HttpClient 替身（不触网，可按 URL 卡住响应做迟到结果）
// ---------------------------------------------------------------------------

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

  /// 每个请求一个闸门：同一个 URL 的第二/第三次请求各有各的 Future，
  /// 否则「失败一次后重试成功」这种两次请求的用例没法分别控制。
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
  _FakeResponse(this._bytes) : status = 200;

  final List<int> _bytes;
  final int status;

  @override
  int get statusCode => status;

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
  /// 每个 URL 一串闸门，按请求顺序排列：测试决定每一次请求什么时候回来。
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('音质：可切换的 provider 上真的落到宿主偏好键 quality', () {
    // 事实先行（复审给出的关键修正）：
    //  * 出厂 provider 只有 siren，而 siren 的音质 choices 只有一档 'lossless'
    //    （settings_modal.dart:2495-2499），descriptor 默认值却是 'exhigh'；
    //    于是 `target == currentCanonical` 的 unchanged 检查先命中
    //    （settings_row.dart:1088），命令在读到映射表之前就返回了。
    //    这不是缺陷，是"只有一档就没什么可切换"——面板如实报 unchanged。
    //  * 这条映射真正的用途在多档 provider（qq/kugou/netease…）：它们的 quality
    //    descriptor 同样没有 preferenceKey，也没有 actionPrefix 之外的键来源，
    //    没有映射时 runtime 会拒绝写入（"这一项没有可持久化的偏好键"）。
    test('qq：quality:set 算得出可写键 quality（Qt MusicPlayer.cpp:139/:181、Host.cpp:1063）', () {
      final SettingsPreferenceSnapshot snapshot = basicSettingsSnapshotFrom(
        <String, String>{'panel/quality': 'exhigh'},
        dark: true,
      );
      final BasicSettingsCommand command = basicSettingsCommandFor(
        'quality:set:lossless',
        context: _settingsContext(providerId: 'qq'),
        snapshot: snapshot,
      );
      expect(command, isA<BasicSettingsWriteCommand>());
      final BasicSettingsWriteCommand write = command as BasicSettingsWriteCommand;
      expect(write.preferenceKey, 'quality',
          reason: '缺这条映射 → runtime 报"这一项没有可持久化的偏好键"，音质只选不存');
      expect(write.value, 'lossless');
      expect(write.dispatchAction, 'quality:set:lossless');
    });

    test('siren 只有一档：任何切换都如实报 unchanged（不伪造写成功）', () {
      final SettingsPreferenceSnapshot snapshot = basicSettingsSnapshotFrom(
        <String, String>{'panel/quality': 'exhigh'},
        dark: true,
      );
      for (final String action in <String>['quality:set:lossless', 'quality:set:exhigh']) {
        final BasicSettingsCommand command = basicSettingsCommandFor(
          action,
          context: _settingsContext(),
          snapshot: snapshot,
        );
        expect(command, isA<BasicSettingsUnavailableCommand>(), reason: action);
        expect((command as BasicSettingsUnavailableCommand).rejection,
            BasicSettingsRejection.unchanged,
            reason: action);
      }
    });

    test('qq：写入后端口里真的有 panel/quality，重新 load 还读得出来', () async {
      final MemoryBasicSettingsPort port =
          MemoryBasicSettingsPort(package: _androidPackage);
      port.values['panel/quality'] = 'exhigh';
      final BasicSettingsRuntime runtime =
          BasicSettingsRuntime(store: BasicSettingsStore(port: port));
      await runtime.load();

      final BasicSettingsApplyResult result = await runtime.apply(
        'quality:set:lossless',
        context: _settingsContext(providerId: 'qq'),
      );
      expect(result.persisted, isTrue);
      expect(result.persistedValue, 'lossless');
      expect(port.values['panel/quality'], 'lossless');

      final BasicSettingsRuntime reloaded =
          BasicSettingsRuntime(store: BasicSettingsStore(port: port));
      await reloaded.load();
      expect(reloaded.raw['panel/quality'], 'lossless');
      expect(reloaded.snapshot.quality, 'lossless');
    });

    test('qq：已是 lossless 时报告 unchanged，值原样不动', () async {
      final MemoryBasicSettingsPort port =
          MemoryBasicSettingsPort(package: _androidPackage);
      port.values['panel/quality'] = 'lossless';
      final BasicSettingsRuntime runtime =
          BasicSettingsRuntime(store: BasicSettingsStore(port: port));
      await runtime.load();
      final BasicSettingsApplyResult result = await runtime.apply(
        'quality:set:lossless',
        context: _settingsContext(providerId: 'qq'),
      );
      expect(result.persisted, isFalse);
      expect(result.persistedValue, '');
      expect(port.values['panel/quality'], 'lossless');
    });
  });

  group('详情自动播放：只有显式打开且设置开着才出声', () {
    late _Server server;
    late _FakeAudio audio;
    late BasicController controller;

    setUp(() async {
      server = _Server();
      audio = _FakeAudio();
      controller = BasicController(audio: audio, repository: server.repository());
      addTearDown(controller.dispose);
      await controller.boot();
      await _settle();
    });

    SirenSong songOf(BasicController target, String title) {
      return target.state.songs.firstWhere((SirenSong song) => song.title == title);
    }

    test('设置关着：打开详情只选中不播放', () async {
      final SirenSong song = songOf(controller, 'Song One');
      expect(controller.state.playing, isFalse);
      audio.calls.clear();

      await controller.openSong(song, play: false);
      await controller.autoplayDetailIfEnabled(song);
      await _settle();

      expect(controller.state.phase, BasicPhase.detail);
      expect(controller.state.playing, isFalse);
      expect(controller.state.status, '已选中：Song One');
      expect(audio.calls.where((String call) => call.startsWith('play:')), isEmpty);
    });

    test('设置开着：打开详情真的起播，且不替换播放列表', () async {
      controller.setDetailAutoplay(true);
      final SirenSong first = songOf(controller, 'Song One');
      final SirenSong second = songOf(controller, 'Song Two');

      // 先让队列里有一首在播（显式播放，replace 语义）。
      await controller.openSong(first, play: true);
      await _settle();
      final int queueBefore = controller.state.queue.length;

      // 再「打开」第二首：自动播放走 music.play(false) 同义路径——不带 source。
      await controller.openSong(second, play: false);
      await controller.autoplayDetailIfEnabled(second);
      await _settle();

      expect(controller.state.status, '正在准备：Song Two');
      expect(audio.calls.where((String call) => call.startsWith('prepare:')), isNotEmpty);
      // 不替换播放列表：原有队列必须还在（Qt 注释"自动播放不触发替换播放列表"）。
      // 只断言"没被替换成单曲"，不锁死"找到即选/找不到才追加"的具体长度。
      expect(controller.state.queue.length, greaterThanOrEqualTo(queueBefore));
      expect(
          controller.state.queue.any((SirenSong item) => item.title == 'Song One'),
          isTrue,
          reason: '自动播放不能把队列换成只有当前这一首');
      expect(controller.state.song?.title, 'Song Two');
    });

    test('已经在播这首时重复打开不重新起播（不打断进度）', () async {
      controller.setDetailAutoplay(true);
      final SirenSong song = songOf(controller, 'Song One');
      await controller.openSong(song, play: true);
      await _settle();
      audio.emit(const BasicAudioState(
          playing: true, positionMs: 1234, durationMs: 20000, generation: 1));
      await _settle();
      final int prepareCount =
          audio.calls.where((String call) => call.startsWith('prepare:')).length;

      await controller.autoplayDetailIfEnabled(song);
      await _settle();
      expect(
          audio.calls.where((String call) => call.startsWith('prepare:')).length,
          prepareCount);
    });

    test('浏览路径（纯选中）即便设置开着也不出声', () async {
      controller.setDetailAutoplay(true);
      audio.calls.clear();
      await controller.selectLibraryRow(1);
      await _settle();
      expect(audio.calls.where((String call) => call.startsWith('prepare:')), isEmpty);
      expect(controller.state.playing, isFalse);
    });
  });

  group('通知封面：远端 URL 落成本地文件，A/B/A 不串台', () {
    late Directory tempDir;
    late _FakeHttpClient client;
    late _FakeMediaPort port;
    late _FakeAudio audio;
    late _Server server;
    late BasicArtCache cache;
    late BasicController controller;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('user_scope_152_art');
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

    /// 起播一首并让它真的"在播"（native 读数由测试 emit，不是本地加时间）。
    Future<void> playAndEmit(SirenSong song) async {
      await controller.openSong(song, play: true);
      await _settle();
      audio.emit(BasicAudioState(
          playing: true, positionMs: 0, durationMs: 20000, generation: 1));
      await _settle();
    }

    /// 等封面请求真的发出（假 client 已登记该 URL 的闸门）。
    ///
    /// 不能靠固定微任务轮数：控制器要先 await 一次目录解析才走到 getUrl，
    /// 轮数不够时 client.gates[...] 还是 null，测试会以空指针而不是断言失败收场。
    Future<Completer<List<int>>> gateFor(String url, [int nth = 0]) async {
      for (int i = 0; i < 200; i += 1) {
        final List<Completer<List<int>>> list = client.gatesFor(url);
        if (list.length > nth) {
          return list[nth];
        }
        await Future<void>.delayed(Duration.zero);
      }
      // 用 throw 而不是 fail()：不依赖 test 包里 fail 的返回类型
      // （若它声明成 void，这个 Future<Completer<…>> 的 async 函数就编译不过）。
      throw StateError('封面请求没有发出：$url（第 ${nth + 1} 次；已请求 ${client.requested.join(', ')}）');
    }

    /// 等到"带本地封面文件的上报"真的出现。
    ///
    /// 落盘走真实 File.writeAsBytes + rename，属于真 IO：16 次零延迟微任务
    /// 不保证它在同一轮跑完，所以按结果轮询，不赌固定轮数。
    Future<MediaSessionState> waitForCover(int fromIndex) async {
      for (int i = 0; i < 400; i += 1) {
        for (final MediaSessionState state in port.updates.skip(fromIndex)) {
          final String path = state.coverPath ?? '';
          if (path.isNotEmpty && File(path).existsSync()) {
            return state;
          }
        }
        await Future<void>.delayed(const Duration(milliseconds: 2));
      }
      throw StateError(
          '没有等到带本地封面的上报（累计 ${port.updates.length} 次上报）');
    }

    test('封面 URL 真的落成本地 img，上报的是文件路径而不是 URL', () async {
      final SirenSong song = songOf('Song One');
      expect(song.cover, 'https://cover.test/a1.jpg');

      await playAndEmit(song);
      // 缓存目录已解析、请求已发出，等本次落盘真正完成（真 IO，按结果轮询）。
      final int before = port.updates.length;
      (await gateFor(song.cover)).complete(<int>[1, 2, 3, 4]);

      final MediaSessionState last = await waitForCover(before);
      expect(last.title, 'Song One');
      expect(last.coverPath, isNotEmpty,
          reason: 'decodeFile 只认本地路径：远端 URL 必须落盘后再上报');
      expect(last.coverPath, isNot(contains('http')));
      expect(File(last.coverPath!).existsSync(), isTrue);
      expect(last.coverPath, endsWith('.img'));
    });

    test('失败（404/无字节）如实留空封面，不抛也不重试失控', () async {
      final SirenSong song = songOf('Song One');
      await playAndEmit(song);
      (await gateFor(song.cover)).complete(<int>[]);
      await _settle();
      expect(port.updates.last.coverPath, '');
      expect(client.requested.length, 1,
          reason: '同一 (id, url) 只请求一次，失败不无限重试');
    });

    test('A -> B -> A：B 的迟到结果不会覆盖回到 A 的封面', () async {
      final SirenSong a = songOf('Song One');
      final SirenSong b = songOf('Song Two');

      await playAndEmit(a); // A 的请求在飞
      await playAndEmit(b); // B 的请求在飞
      await playAndEmit(a); // 回到 A：新一代请求

      // 先让 A 落盘（当前身份是 A，允许上报）。
      final int beforeA = port.updates.length;
      (await gateFor(a.cover)).complete(<int>[9, 9, 9]);
      final MediaSessionState stateA = await waitForCover(beforeA);
      final String coverA = stateA.coverPath ?? '';
      expect(coverA, isNotEmpty);
      expect(stateA.title, 'Song One');

      // 再让 B 迟到回来：代次与身份都已过期，必须被丢弃。
      (await gateFor(b.cover)).complete(<int>[7, 7, 7]);
      await _settle();
      expect(port.updates.last.coverPath, coverA);
      expect(port.updates.last.title, 'Song One');
      expect(File(coverA).existsSync(), isTrue);
    });

    test('切到 B 的瞬间上报的封面是空的：绝不把上一首的图贴给 B', () async {
      final SirenSong a = songOf('Song One');
      final SirenSong b = songOf('Song Two');
      await playAndEmit(a);
      final int beforeA = port.updates.length;
      (await gateFor(a.cover)).complete(<int>[5, 6]);
      final String coverA = (await waitForCover(beforeA)).coverPath ?? '';
      expect(coverA, isNotEmpty);

      // B 的封面还没回来：这一次上报必须是"还没有封面"，而不是 A 的路径。
      final int before = port.updates.length;
      await playAndEmit(b);
      final MediaSessionState firstB = port.updates
          .skip(before)
          .firstWhere((MediaSessionState state) => state.title == 'Song Two');
      expect(firstB.coverPath, '');
      expect(firstB.coverPath, isNot(coverA));
    });

    test('同一身份换了封面 URL：旧请求迟到落地也不许贴上来', () async {
      final SirenSong a = songOf('Song One');
      await playAndEmit(a);
      final Completer<List<int>> oldGate = await gateFor(a.cover, 0);

      // 曲库这张专辑的封面换成了另一张（详情覆盖曲库值）：同一个 s1 身份、不同 URL。
      server.albumCovers['a1'] = 'https://cover.test/a1b.jpg';
      final SirenAlbum album = controller.state.albums
          .firstWhere((SirenAlbum item) => item.id == 'a1');
      await controller.openAlbum(album);
      await _settle();

      // 换 URL 的那一刻就必须如实上报"没有封面"，而不是继续贴旧图。
      expect(port.updates.last.coverPath, '');
      expect(port.updates.last.title, 'Song One');

      // 旧 URL 的结果现在才回来：代次已作废，必须整份丢弃。
      oldGate.complete(<int>[1, 2, 3, 4]);
      await _settle();
      expect(port.updates.last.coverPath, '');
      expect(
          port.updates.every(
              (MediaSessionState state) => (state.coverPath ?? '').isEmpty),
          isTrue,
          reason: '旧 URL 的结果一条都不许上报（没有后续事件也照样不许）');

      // 新 URL 落地后才允许贴图，且文件内容必须是新字节 —— 这是"不是旧结果"的硬证据。
      final int beforeNew = port.updates.length;
      (await gateFor('https://cover.test/a1b.jpg', 0)).complete(<int>[9, 9, 9]);
      final MediaSessionState fresh = await waitForCover(beforeNew);
      expect(fresh.coverPath, isNotEmpty);
      expect(File(fresh.coverPath!).readAsBytesSync(), <int>[9, 9, 9]);
    });

    test('一次瞬时失败后有界重试：第二次成功就贴上来，且不会无限重试', () async {
      final SirenSong a = songOf('Song One');
      await playAndEmit(a);
      (await gateFor(a.cover, 0)).complete(<int>[]); // 空字节 = 这次抓取失败
      await _settle();
      expect(port.updates.last.coverPath, '');
      expect(client.requested.where((String url) => url == a.cover).length, 1,
          reason: '第一次失败当下不补发，避免同步重试循环');

      // 下一次上报允许补一次（上限 2 次）。
      final int before = port.updates.length;
      audio.emit(BasicAudioState(
          playing: true, positionMs: 500, durationMs: 20000, generation: 1));
      await _settle();
      expect(client.requested.where((String url) => url == a.cover).length, 2);

      (await gateFor(a.cover, 1)).complete(<int>[7, 7, 7]);
      final MediaSessionState fresh = await waitForCover(before);
      expect(fresh.coverPath, isNotEmpty);
      expect(File(fresh.coverPath!).readAsBytesSync(), <int>[7, 7, 7]);

      // 已经有封面之后，再怎么上报也不会再发请求。
      audio.emit(BasicAudioState(
          playing: true, positionMs: 900, durationMs: 20000, generation: 1));
      await _settle();
      expect(client.requested.where((String url) => url == a.cover).length, 2);
    });

    test('dispose 关掉封面缓存：之后不再写盘', () async {
      controller.dispose();
      await _settle();
      final String? after = await cache.localPath('https://cover.test/a1.jpg');
      expect(after, isNull);
      expect(port.disposes, 1);
    });
  });

  group('静态护栏（不是设备 PASS）', () {
    final File kotlinChannel = File(
        'android/app/src/main/kotlin/rhine/music/database/porting/MediaSessionChannel.kt');
    final File kotlinHost = File(
        'android/app/src/main/kotlin/rhine/music/database/porting/MediaSessionHost.kt');
    final File dartController = File('lib/basic/siren_controller.dart');
    final File dartSettings = File('lib/basic/basic_settings.dart');

    test('cacheDir 方法真的在 Kotlin 侧实现（否则封面目录永远拿不到）', () {
      final String source = kotlinChannel.readAsStringSync();
      expect(source, contains('METHOD_CACHE_DIR = "cacheDir"'));
      expect(source, contains('appContext?.cacheDir?.absolutePath'));
      expect(source, contains('METHOD_ENSURE_STARTED = "ensureStarted"'));
    });

    test('通知只从 decodeFile 读本地封面，不认 http', () {
      final String source = kotlinHost.readAsStringSync();
      expect(source, contains('BitmapFactory.decodeFile'));
      expect(source, isNot(contains('decodeStream(URL')));
    });

    test('音质映射表里确实有 quality（否则多档 provider 只选不存）', () {
      final String source = dartSettings.readAsStringSync();
      expect(source, contains("'quality': 'quality',"));
    });

    test('宿主只在"显式打开详情"这一条路径上接线自动播放（浏览/选中不接线）', () {
      final String source = File('lib/basic/basic_app.dart').readAsStringSync();
      expect(source, contains('unawaited(controller.autoplayDetailIfEnabled('),
          reason: '没接线 = 设置开着也不出声');
      expect(source, contains('if (!play) {'),
          reason: '只允许在 play:false 的显式打开分支调用；浏览路径走 _selectAt，不该出声');
      expect(source, contains('unawaited(controller.autoplayDetailIfEnabled(tracks[item.index]));'),
          reason: '断言到具体调用点，避免同形分支冒充接线');
    });

    test('换封面 URL / 换成空 URL 时先作废代次，再走早退（顺序不能反）', () {
      final String source = dartController.readAsStringSync();
      final int bump = source.indexOf('cache.beginGeneration();');
      final int emptyReturn = source.indexOf('if (url.isEmpty) {');
      final int attemptsGate = source.indexOf('_artAttempts >= _artMaxAttempts');
      expect(bump, greaterThan(-1));
      expect(emptyReturn, greaterThan(-1));
      expect(bump, lessThan(emptyReturn),
          reason: '代次必须在空 URL 早退之前递增，否则同一 (id,url) 的旧闭包会写回旧图');
      expect(bump, lessThan(attemptsGate));
      expect(source, contains('_artUrl != requestUrl'),
          reason: '闭包里要复核捕获到的 URL，不只看代次与身份');
    });

    test('封面重试有界：有上限常量与比较，不是无限重试循环', () {
      final String source = dartController.readAsStringSync();
      expect(source, contains('static const int _artMaxAttempts'));
      expect(source, contains('_artAttempts >= _artMaxAttempts'));
      expect(source, contains('_artAttempts += 1'));
      expect(source, contains('if (_artInFlight >= 0)'),
          reason: '在飞闸门必须在建闭包之前：否则起步阶段多个闭包会重复记额度、把重试机会吃光');
    });

    test('本机集合缓存签名带内容摘要（同长度替换也算变化）', () {
      final String source = dartController.readAsStringSync();
      expect(source, contains('String _collectionsDigest()'));
      expect(source, contains('_collectionsDigest(),'),
          reason: '摘要必须真的进了 _laneItemTable 的签名数组');
      expect(source, isNot(contains('_likedSongs.length,')),
          reason: '只数长度的项已被内容摘要取代');
    });

    test('控制器把本地封面路径交给身份，且 dispose 关缓存', () {
      final String source = dartController.readAsStringSync();
      expect(source, contains('coverFilePath: cover'));
      expect(source, contains('_artCache = artCache ?? BasicArtCache('));
      expect(source, contains('unawaited(artCache.close())'));
    });
  });
}
