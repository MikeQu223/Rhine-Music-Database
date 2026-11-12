// EXECUTION STATUS: NOT EXECUTED.
//
// This worktree forbids flutter test / dart test / build / analyze / pub get. The tests
// below are written for later execution on a machine with the Flutter SDK:
//
//   flutter test test/basic/platform_playback_test.dart
//
// RED/GREEN are unknown until that command runs. The last group reads the working-tree
// source text (File.readAsStringSync: what is on disk now, not what is in git HEAD), so it
// needs no engine, platform channel, or device.

import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rhine_music_database/basic/platform_playback.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const MethodChannel methodChannel = MethodChannel(basicAudioChannel);
  const EventChannel eventChannel = EventChannel(basicAudioStateChannel);

  late List<MethodCall> calls;
  late _RecordingStreamHandler events;

  /// 平台状态 map 的测试构造器；键与 Kotlin 侧 snapshot() 逐字一致。
  Map<String, Object?> stateMap({
    bool playing = false,
    bool buffering = false,
    bool completed = false,
    double positionMs = 0,
    double durationMs = 0,
    int generation = 0,
    String error = '',
  }) {
    return <String, Object?>{
      'playing': playing,
      'buffering': buffering,
      'completed': completed,
      'positionMs': positionMs,
      'durationMs': durationMs,
      'generation': generation,
      'error': error,
    };
  }

  setUp(() {
    calls = <MethodCall>[];
    events = _RecordingStreamHandler();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(methodChannel, (MethodCall call) async {
      calls.add(call);
      // 默认不回包：调用成功但返回 null。状态只由测试显式推的事件决定，
      // 这样边界断言不会被 mock 的"回包"污染。
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(methodChannel, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockStreamHandler(eventChannel, null);
  });

  /// 先注册事件 mock 再构造端口：端口的构造函数会立刻 send listen。
  Future<MethodChannelBasicAudio> createAudio() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockStreamHandler(eventChannel, events);
    final MethodChannelBasicAudio audio = MethodChannelBasicAudio(
      methodChannel: methodChannel,
      eventChannel: eventChannel,
    );
    await pumpEventQueue();
    return audio;
  }

  group('MethodChannelBasicAudio transport', () {
    test('sends prepare with the caller generation and a loading state', () async {
      final MethodChannelBasicAudio audio = await createAudio();

      await audio.prepare('https://example.test/a.mp3', generation: 3);
      await pumpEventQueue();

      expect(calls.length, 1);
      expect(calls.single.method, 'prepare');
      expect(calls.single.arguments, <String, Object?>{
        'url': 'https://example.test/a.mp3',
        'generation': 3,
      });
      // 本地先落"正在加载"：没有播放（没有声音就不可能有 playing），代际是调用方给的。
      expect(audio.state.buffering, isTrue);
      expect(audio.state.playing, isFalse);
      expect(audio.state.generation, 3);
      expect(audio.state.positionMs, 0);
      expect(audio.state.durationMs, 0);
      expect(audio.state.error, '');

      await audio.dispose();
    });

    test('refuses an empty url without touching the platform', () async {
      final MethodChannelBasicAudio audio = await createAudio();

      await audio.prepare('', generation: 1);
      await pumpEventQueue();

      expect(calls, isEmpty);
      expect(audio.state.error, isNotEmpty);
      expect(audio.state.playing, isFalse);

      await audio.dispose();
    });

    test('drops play/pause/seek commands whose generation is stale', () async {
      final MethodChannelBasicAudio audio = await createAudio();
      await audio.prepare('https://example.test/a.mp3', generation: 3);
      calls.clear();

      await audio.play(generation: 2);
      await audio.pause(generation: 2);
      await audio.seekTo(1000, generation: 2);
      await pumpEventQueue();

      expect(calls, isEmpty, reason: 'stale generation must not reach the platform');

      await audio.dispose();
    });

    test('sends play/pause/seek for the accepted generation', () async {
      final MethodChannelBasicAudio audio = await createAudio();
      await audio.prepare('https://example.test/a.mp3', generation: 4);
      calls.clear();

      await audio.play(generation: 4);
      await audio.pause(generation: 4);
      await audio.seekTo(1500, generation: 4);
      await pumpEventQueue();

      expect(
        calls.map((MethodCall call) => call.method).toList(),
        <String>['play', 'pause', 'seekTo'],
      );
      expect(calls.last.arguments, <String, Object?>{
        'positionMs': 1500.0,
        'generation': 4,
      });

      await audio.dispose();
    });
  });

  group('generation filtering of platform events', () {
    test('drops a late state event from an older generation', () async {
      final MethodChannelBasicAudio audio = await createAudio();
      await audio.prepare('https://example.test/a.mp3', generation: 5);
      await pumpEventQueue();

      final List<BasicAudioState> seen = <BasicAudioState>[];
      audio.addListener(seen.add);

      events.emit(stateMap(
        playing: true,
        positionMs: 900,
        durationMs: 4000,
        generation: 4,
      ));
      await pumpEventQueue();

      expect(audio.state.generation, 5);
      expect(audio.state.playing, isFalse);
      expect(audio.state.positionMs, 0);
      expect(seen, isEmpty);

      await audio.dispose();
    });

    test('a fresh client may restart generation at 1 after dispose', () async {
      final MethodChannelBasicAudio first = await createAudio();
      await first.prepare('https://example.test/a.mp3', generation: 5);
      await first.play(generation: 5);
      await first.dispose();
      await pumpEventQueue();
      calls.clear();

      // 新客户端 = 新 controller：Dart 侧代际从 1 重新数。Kotlin 侧曾经按「小于即旧代」
      // 拒绝 prepare，导致同进程内第二次进 App 全程无声；这里钉住新客户端仍能开工。
      final MethodChannelBasicAudio second = await createAudio();
      await second.prepare('https://example.test/b.mp3', generation: 1);
      await pumpEventQueue();

      expect(calls.single.method, 'prepare');
      expect(calls.single.arguments, <String, Object?>{
        'url': 'https://example.test/b.mp3',
        'generation': 1,
      });

      events.emit(stateMap(
        playing: true,
        positionMs: 120,
        durationMs: 3000,
        generation: 1,
      ));
      await pumpEventQueue();

      expect(second.state.playing, isTrue);
      expect(second.state.generation, 1);
      expect(second.state.positionMs, 120);

      await second.dispose();
    });

    test('a stale snapshot pushed on listen does not swallow the first prepare',
        () async {
      // 真实 EventChannel 的 onListen 会立刻补推一份当前快照（Kotlin :109）。authority 跨客户端
      // 复用，所以这份快照可能还带着上一次会话的代际（这里用 7）：Dart 若按「小于已采纳代际
      // 就丢弃」处理 prepare，新客户端的 prepare(1) 连通道都发不出去 → 首曲无声、error 为空。
      // Kotlin 侧的 onClientAttached 已把 generation 归零；这里同时钉住 Dart 侧不再自设地板砖。
      final MethodChannelBasicAudio audio = await createAudio();

      events.emit(stateMap(
        playing: true,
        positionMs: 5000,
        durationMs: 9000,
        generation: 7,
      ));
      await pumpEventQueue();
      expect(audio.state.generation, 7, reason: '旧快照被采纳，地板砖被抬到 7');

      await audio.prepare('https://example.test/first.mp3', generation: 1);
      await pumpEventQueue();

      expect(calls.map((MethodCall call) => call.method).toList(), <String>['prepare']);
      expect(calls.single.arguments, <String, Object?>{
        'url': 'https://example.test/first.mp3',
        'generation': 1,
      });
      expect(audio.state.generation, 1);
      expect(audio.state.buffering, isTrue);
      expect(audio.state.error, '');

      // 采纳 1 之后 play(1) 也必须能下发：否则就是「准备成功但按了没反应」。
      calls.clear();
      await audio.play(generation: 1);
      await pumpEventQueue();
      expect(calls.single.method, 'play');

      await audio.dispose();
    });

    test('adopts the accepted generation and notifies once per distinct state',
        () async {
      final MethodChannelBasicAudio audio = await createAudio();
      await audio.prepare('https://example.test/a.mp3', generation: 5);
      await pumpEventQueue();

      final List<BasicAudioState> seen = <BasicAudioState>[];
      audio.addListener(seen.add);

      final Map<String, Object?> playing = stateMap(
        playing: true,
        positionMs: 400,
        durationMs: 3000,
        generation: 5,
      );
      events.emit(playing);
      await pumpEventQueue();
      expect(audio.state.playing, isTrue);
      expect(audio.state.positionMs, 400);
      expect(audio.state.durationMs, 3000);
      expect(seen.length, 1);

      // 同一份快照再来一次：值对象相等，不再通知。
      events.emit(playing);
      await pumpEventQueue();
      expect(seen.length, 1);

      events.emit(stateMap(
        playing: false,
        completed: true,
        positionMs: 3000,
        durationMs: 3000,
        generation: 5,
      ));
      await pumpEventQueue();
      expect(audio.state.completed, isTrue);
      expect(audio.state.playing, isFalse);
      expect(seen.length, 2);
      expect(seen.last.completed, isTrue);

      await audio.dispose();
    });

    test('ignores a payload that is not a state map', () async {
      final MethodChannelBasicAudio audio = await createAudio();
      await audio.prepare('https://example.test/a.mp3', generation: 2);
      await pumpEventQueue();
      final BasicAudioState before = audio.state;

      events.emit('not-a-map');
      await pumpEventQueue();

      expect(audio.state, before);

      await audio.dispose();
    });
  });

  group('seek boundaries', () {
    test('clamps to [0, duration] with the platform-reported duration', () async {
      final MethodChannelBasicAudio audio = await createAudio();
      await audio.prepare('https://example.test/a.mp3', generation: 1);
      // 平台上一次报的真实时长；夹取上界取这个值。
      events.emit(stateMap(durationMs: 5000, generation: 1));
      await pumpEventQueue();
      calls.clear();

      await audio.seekTo(-100, generation: 1);
      await audio.seekTo(999999, generation: 1);
      await audio.seekTo(double.nan, generation: 1);
      await audio.seekTo(double.infinity, generation: 1);
      await audio.seekTo(2500, generation: 1);

      expect(
        calls.map((MethodCall call) =>
            (call.arguments as Map<Object?, Object?>)['positionMs']).toList(),
        <double>[0.0, 5000.0, 0.0, 5000.0, 2500.0],
      );

      await audio.dispose();
    });

    test('clampSeekPosition is the single boundary rule', () {
      expect(clampSeekPosition(-1, 0), 0);
      expect(clampSeekPosition(double.nan, 800), 0);
      expect(clampSeekPosition(double.infinity, 0), 0);
      expect(clampSeekPosition(double.infinity, 800), 800);
      expect(clampSeekPosition(1200, 800), 800);
      expect(clampSeekPosition(1200, 0), 1200);
      expect(clampSeekPosition(300, 800), 300);
    });
  });

  group('error states', () {
    test('reports a platform error instead of throwing when the channel is absent',
        () async {
      // 模拟非 Android 平台：通道没有任何实现。
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(methodChannel, null);
      final MethodChannelBasicAudio audio = await createAudio();

      await audio.prepare('https://example.test/a.mp3', generation: 1);
      await pumpEventQueue();

      expect(audio.state.error, isNotEmpty);
      expect(audio.state.playing, isFalse);
      expect(audio.state.buffering, isFalse);
      expect(audio.state.generation, 1);

      await audio.dispose();
    });

    test('a platform error event sets the error and clears the playback flags',
        () async {
      final MethodChannelBasicAudio audio = await createAudio();
      await audio.prepare('https://example.test/a.mp3', generation: 6);
      await pumpEventQueue();
      final List<BasicAudioState> seen = <BasicAudioState>[];
      audio.addListener(seen.add);

      events.emit(stateMap(
        playing: false,
        error: '播放失败（what=1, extra=-1004）',
        generation: 6,
      ));
      await pumpEventQueue();

      expect(audio.state.error, contains('what=1'));
      expect(audio.state.playing, isFalse);
      expect(audio.state.buffering, isFalse);
      expect(seen.single.error, contains('what=1'));

      await audio.dispose();
    });

    test('refresh reads the state through getState', () async {
      final MethodChannelBasicAudio audio = await createAudio();

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(methodChannel, (MethodCall call) async {
        calls.add(call);
        if (call.method == 'getState') {
          return stateMap(playing: true, positionMs: 700, durationMs: 2000, generation: 2);
        }
        return null;
      });

      await audio.prepare('https://example.test/a.mp3', generation: 2);
      final BasicAudioState? refreshed = await audio.refresh();

      expect(calls.last.method, 'getState');
      expect(refreshed?.playing, isTrue);
      expect(audio.state.positionMs, 700);
      expect(audio.state.durationMs, 2000);

      await audio.dispose();
    });
  });

  group('dispose safety', () {
    test('is a no-op after dispose and never throws', () async {
      final MethodChannelBasicAudio audio = await createAudio();
      await audio.dispose();
      expect(audio.isDisposed, isTrue);
      expect(audio.state, BasicAudioState.idle);
      calls.clear();

      await audio.prepare('https://example.test/a.mp3', generation: 9);
      await audio.play(generation: 9);
      await audio.pause(generation: 9);
      await audio.seekTo(10, generation: 9);
      await audio.stop();
      await audio.dispose();
      await pumpEventQueue();

      expect(calls, isEmpty, reason: 'dispose must not leave outbound calls');
      expect(await audio.refresh(), isNull);
    });

    test('dispose is idempotent and stops notifying listeners', () async {
      final MethodChannelBasicAudio audio = await createAudio();
      int notifications = 0;
      audio.addListener((BasicAudioState _) => notifications += 1);

      await audio.dispose();
      final int afterDispose = notifications;
      await audio.dispose();
      audio.addListener((BasicAudioState _) => notifications += 1);
      await pumpEventQueue();

      expect(notifications, afterDispose);
      expect(calls.where((MethodCall call) => call.method == 'dispose').length, 1);
    });

    test('cancels the event subscription exactly once', () async {
      final MethodChannelBasicAudio audio = await createAudio();
      expect(events.listens, 1);

      await audio.dispose();
      await pumpEventQueue();

      expect(events.cancels, 1);
    });
  });

  group('BasicAudioState parsing', () {
    test('ignores non-map payloads and clamps impossible numbers', () {
      expect(BasicAudioState.tryParse(null), isNull);
      expect(BasicAudioState.tryParse('nope'), isNull);
      expect(BasicAudioState.tryParse(<Object?>[]), isNull);

      final BasicAudioState? parsed = BasicAudioState.tryParse(<String, Object?>{
        'playing': 'yes', // 只有布尔 true 才算真（QJsonValue::toBool 语义）
        'buffering': true,
        'completed': 1,
        'positionMs': -5,
        'durationMs': 'x',
        'generation': 3.0,
        'error': 42,
      });

      expect(parsed, isNotNull);
      expect(parsed!.playing, isFalse);
      expect(parsed.buffering, isTrue);
      expect(parsed.completed, isFalse);
      expect(parsed.positionMs, 0);
      expect(parsed.durationMs, 0);
      expect(parsed.generation, 3);
      expect(parsed.error, '');
      expect(parsed.hasError, isFalse);
    });

    test('is a value object with copyWith', () {
      const BasicAudioState left = BasicAudioState(
        playing: true,
        positionMs: 100,
        durationMs: 900,
        generation: 2,
      );
      const BasicAudioState right = BasicAudioState(
        playing: true,
        positionMs: 100,
        durationMs: 900,
        generation: 2,
      );
      expect(left, right);
      expect(left.hashCode, right.hashCode);

      final BasicAudioState next = left.copyWith(playing: false, error: 'x');
      expect(next.playing, isFalse);
      expect(next.error, 'x');
      expect(next.positionMs, 100);
      expect(next, isNot(left));
      expect(left.toMap().keys.toSet(), <String>{
        'playing',
        'buffering',
        'completed',
        'positionMs',
        'durationMs',
        'generation',
        'error',
      });
    });
  });

  group('source contract', () {
    test('Kotlin channel names, real MediaPlayer use and MainActivity stay in sync',
        () {
      final String kotlin = File(
        'android/app/src/main/kotlin/rhine/music/database/basic/BasicAudioChannel.kt',
      ).readAsStringSync();
      final String activity = File(
        'android/app/src/main/kotlin/rhine/music/database/MainActivity.kt',
      ).readAsStringSync();

      expect(
        kotlin,
        contains('const val METHOD_CHANNEL = "rhine.music.database/basic_audio"'),
      );
      expect(
        kotlin,
        contains('const val EVENT_CHANNEL = "rhine.music.database/basic_audio_state"'),
      );
      // 真播放：系统 MediaPlayer + 音乐用途 + 异步准备。
      expect(kotlin, contains('import android.media.MediaPlayer'));
      expect(kotlin, contains('AudioAttributes.USAGE_MEDIA'));
      expect(kotlin, contains('AudioAttributes.CONTENT_TYPE_MUSIC'));
      expect(kotlin, contains('prepareAsync()'));
      expect(kotlin, contains('setAudioAttributes'));
      // 位置只读不推：没有自增、没有假 timer。
      expect(kotlin, contains('currentPosition'));
      expect(kotlin, isNot(contains('positionMs +=')));
      expect(kotlin, isNot(contains('Timer(')));
      // 释放路径真的走 MediaPlayer.release()。
      expect(kotlin, contains('mp.release()'));
      // 唯一播放权威：全文件只构造一次 MediaPlayer（匹配 '= MediaPlayer()'，
      // 注释里出现的 'new MediaPlayer()' 不算，所以才不是朴素 contains）。
      expect(RegExp(r'= MediaPlayer\(\)').allMatches(kotlin).length, 1);
      // 本文件不建、不更新 MediaSession：那条线只做系统通知展示（porting/MediaSessionChannel.kt），
      // 喂状态是 Dart 调用方的事，Kotlin 音频层不得反向注册（否则双播放权威）。
      expect(kotlin, isNot(contains('MediaSessionCompat')));
      expect(kotlin, isNot(contains('MediaSessionChannel.install')));

      final int superIndex =
          activity.indexOf('super.configureFlutterEngine(flutterEngine)');
      final int mediaIndex = activity.indexOf('MediaSessionChannel.install(');
      final int audioIndex = activity.indexOf('BasicAudioChannel.install(');
      final int sceneIndex = activity.indexOf('BasicSceneViewFactory.install(');
      expect(superIndex, greaterThanOrEqualTo(0));
      expect(mediaIndex, greaterThan(superIndex));
      expect(audioIndex, greaterThan(mediaIndex));
      expect(sceneIndex, greaterThan(audioIndex));
      // 既有返回键与窗口形态的入口一个都不能动。
      expect(activity, contains('override fun setFrameworkHandlesBack'));
      expect(activity, contains('applyImmersiveSticky()'));
    });
  });
}

/// 记录 listen/cancel 并允许测试手动推事件（与 test/media_session_test.dart 的写法一致）。
class _RecordingStreamHandler extends MockStreamHandler {
  int listens = 0;
  int cancels = 0;
  MockStreamHandlerEventSink? _sink;

  @override
  void onListen(Object? arguments, MockStreamHandlerEventSink events) {
    listens += 1;
    _sink = events;
  }

  @override
  void onCancel(Object? arguments) {
    cancels += 1;
    _sink = null;
  }

  void emit(Object? state) {
    _sink?.success(state);
  }

  void emitError(String code, String message) {
    _sink?.error(code: code, message: message);
  }
}
