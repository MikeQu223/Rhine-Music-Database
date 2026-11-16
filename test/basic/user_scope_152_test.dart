// USER-SCOPE-152 · 设置 / 系统媒体 / 通知封面的接线回归（只写不跑）。
//
// EXECUTION STATUS: NOT EXECUTED.
//
// 本 worktree 禁止 flutter test / dart test / build / analyze / pub get / format / ADB。
// 交付方（FINAL-VERIFY-154）在真机上执行：
//
//   flutter test test/basic/user_scope_152_test.dart
//   flutter test test/basic/basic_settings_145_test.dart
//   flutter test test/basic/basic_media_146_test.dart
//   flutter test test/basic/library_scroll_sync_141_test.dart
//
// RED/GREEN 在跑过之前一律未知。最后一个 group 只读工作树里的源码文本（静态护栏），
// 它证明的是"代码里写着这条路径"，**不是**设备上通知真的显示了 —— 通知可见性、
// POST_NOTIFICATIONS 授权、前台服务存活只能由 154 在实机验收。
//
// 本文件守住 152 补的三条真实接线（都在既有函数上，不重写）：
//   1. 音质（ONLY14 之一）真的能落到宿主偏好键 "quality"：
//      Qt/src/MusicPlayer.cpp:139 setPreference("quality", value)、:181 读回，
//      白名单 Qt/src/Host.cpp:1063。没有这条映射时面板会如实拒绝写入，
//      于是"能选不能存"。
//   2. 详情页自动播放真的出声：Qt/src/NativeHudController.cpp:626-638 —— 只有
//      动作 "open" 且 preference("detail-autoplay")=="on" 才 music.play(false)
//      （不替换播放列表）。浏览/翻行永远不播。
//   3. 通知封面真的走"远端 URL -> 应用私有目录里的真实文件"：
//      MediaSessionHost 只认本地路径（BitmapFactory.decodeFile），所以
//      SirenSong.cover（远端 URL）必须先过 BasicArtCache；A/B/A 迟到结果
//      不能串台。
//
// 真值来源（只读）：Qt/src/NativeHudController.cpp:626-638、Qt/src/MusicPlayer.cpp:139/
// :181、Qt/src/Host.cpp:1063、android/.../MediaSessionChannel.kt（cacheDir）、
// android/.../MediaSessionHost.kt（decodeFile）、lib/platform/media_session.dart。

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

SettingsPreferenceContext _settingsContext() => const SettingsPreferenceContext(
      capabilities: PlatformCapabilities.android(),
      operatingSystem: SettingsOperatingSystem.android,
      providerId: 'siren',
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
          'name': 'Song $id',
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
  _FakeRequest(this._client, this.uri);

  final _FakeHttpClient _client;

  @override
  final Uri uri;

  @override
  final HttpHeaders headers = _FakeHeaders();

  @override
  Future<HttpClientResponse> close() => _client.respond(uri);

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _FakeResponse implements HttpClientResponse {
  _FakeResponse(this._bytes, {this.status = 200});

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
  /// 每个 URL 一个 Future：测试决定它什么时候回来（迟到结果是本文件的重点）。
  final Map<String, Completer<List<int>>> gates =
      <String, Completer<List<int>>>{};
  final List<String> requested = <String>[];

  @override
  Duration? connectionTimeout;

  @override
  Future<HttpClientRequest> getUrl(Uri url) async {
    requested.add(url.toString());
    gates.putIfAbsent(url.toString(), () => Completer<List<int>>());
    return _FakeRequest(this, url);
  }

  Future<HttpClientResponse> respond(Uri url) async {
    final Completer<List<int>> gate =
        gates.putIfAbsent(url.toString(), () => Completer<List<int>>());
    final List<int> bytes = await gate.future;
    return _FakeResponse(bytes);
  }

  @override
  void close({bool force = false}) {}

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('音质：真的落到宿主偏好键 quality', () {
    test('quality:set 在 siren 上算得出可写键（Qt MusicPlayer.cpp:139）', () {
      final SettingsPreferenceSnapshot snapshot = basicSettingsSnapshotFrom(
        <String, String>{'panel/quality': 'exhigh'},
        dark: true,
      );
      final BasicSettingsCommand command = basicSettingsCommandFor(
        'quality:set:lossless',
        context: _settingsContext(),
        snapshot: snapshot,
      );
      expect(command, isA<BasicSettingsWriteCommand>());
      final BasicSettingsWriteCommand write = command as BasicSettingsWriteCommand;
      expect(write.preferenceKey, 'quality',
          reason: '没有这条映射时 runtime 会拒绝写入（"这一项没有可持久化的偏好键"），'
              '于是音质只在界面上选得动、存不下');
      expect(write.dispatchAction, 'quality:set:lossless');
    });

    test('写入后端口里真的有 panel/quality，重新 load 还读得出来', () async {
      final MemoryBasicSettingsPort port =
          MemoryBasicSettingsPort(package: _androidPackage);
      port.values['panel/quality'] = 'exhigh';
      final BasicSettingsRuntime runtime =
          BasicSettingsRuntime(store: BasicSettingsStore(port: port));
      await runtime.load();

      final BasicSettingsApplyResult result =
          await runtime.apply('quality:set:lossless', context: _settingsContext());
      expect(result.persisted, isTrue);
      expect(result.persistedValue, 'lossless');
      expect(port.values['panel/quality'], 'lossless');

      final BasicSettingsRuntime reloaded =
          BasicSettingsRuntime(store: BasicSettingsStore(port: port));
      await reloaded.load();
      expect(reloaded.raw['panel/quality'], 'lossless');
      expect(reloaded.snapshot.quality, 'lossless');
    });

    test('已是 lossless 时报告 unchanged，不写第二个键', () async {
      final MemoryBasicSettingsPort port =
          MemoryBasicSettingsPort(package: _androidPackage);
      port.values['panel/quality'] = 'lossless';
      final BasicSettingsRuntime runtime =
          BasicSettingsRuntime(store: BasicSettingsStore(port: port));
      await runtime.load();
      final BasicSettingsApplyResult result =
          await runtime.apply('quality:set:lossless', context: _settingsContext());
      expect(result.persisted, isFalse);
      expect(result.persistedValue, '');
      // 没写入：端口里的值原样不动（MemoryBasicSettingsPort 不记录写次数，
      // 所以断言"值没被改成别的"）
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

    test('封面 URL 真的落成本地 img，上报的是文件路径而不是 URL', () async {
      final SirenSong song = songOf('Song One');
      expect(song.cover, 'https://cover.test/a1.jpg');

      await playAndEmit(song);
      // 缓存目录已解析、请求已发出，等本次落盘完成。
      client.gates[song.cover]!.complete(<int>[1, 2, 3, 4]);
      await _settle();

      final MediaSessionState last = port.updates.last;
      expect(last.title, 'Song One');
      expect(last.coverPath, isNotEmpty,
          reason: 'decodeFile 只认本地路径：远端 URL 必须落盘后再上报');
      expect(last.coverPath, isNot(contains('http')));
      expect(File(last.coverPath).existsSync(), isTrue);
      expect(last.coverPath, endsWith('.img'));
    });

    test('失败（404/无字节）如实留空封面，不抛也不重试失控', () async {
      final SirenSong song = songOf('Song One');
      await playAndEmit(song);
      client.gates[song.cover]!.complete(<int>[]);
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
      client.gates[a.cover]!.complete(<int>[9, 9, 9]);
      await _settle();
      final String coverA = port.updates.last.coverPath;
      expect(coverA, isNotEmpty);
      expect(port.updates.last.title, 'Song One');

      // 再让 B 迟到回来：代次与身份都已过期，必须被丢弃。
      client.gates[b.cover]!.complete(<int>[7, 7, 7]);
      await _settle();
      expect(port.updates.last.coverPath, coverA);
      expect(port.updates.last.title, 'Song One');
      expect(File(coverA).existsSync(), isTrue);
    });

    test('切到 B 的瞬间上报的封面是空的：绝不把上一首的图贴给 B', () async {
      final SirenSong a = songOf('Song One');
      final SirenSong b = songOf('Song Two');
      await playAndEmit(a);
      client.gates[a.cover]!.complete(<int>[5, 6]);
      await _settle();
      final String coverA = port.updates.last.coverPath;
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

    test('控制器把本地封面路径交给身份，且 dispose 关缓存', () {
      final String source = dartController.readAsStringSync();
      expect(source, contains('coverFilePath: cover'));
      expect(source, contains('_artCache = artCache ?? BasicArtCache('));
      expect(source, contains('unawaited(artCache.close())'));
    });
  });
}
