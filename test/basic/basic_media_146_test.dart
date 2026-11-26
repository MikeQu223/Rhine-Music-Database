// 覆盖 MEDIA-CONTROLS-146 的 Dart 适配器契约：真实身份与 native 读数上报、
// 空/错误清通知、动作回权威、SEEK 按真实时长夹取、dispose 断订阅。
// 运行：flutter test test/basic/basic_media_146_test.dart（只读源码文本，不需设备）。

import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rhine_music_database/basic/basic_media_session.dart';
import 'package:rhine_music_database/basic/platform_playback.dart';
import 'package:rhine_music_database/platform/media_session.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakePort port;
  late _FakeCommands commands;
  late DateTime now;

  const BasicMediaIdentity track = BasicMediaIdentity(
    id: 'siren:song:7',
    title: 'Blue Bird',
    artist: 'Ikimono-gakari',
    album: 'Blue Bird',
  );

  /// 真实 native 读数的测试构造器；键与 Kotlin 侧 snapshot() 逐字一致。
  BasicAudioState audio({
    bool playing = false,
    bool buffering = false,
    double positionMs = 0,
    double durationMs = 0,
    int generation = 1,
    String error = '',
  }) {
    return BasicAudioState(
      playing: playing,
      buffering: buffering,
      positionMs: positionMs,
      durationMs: durationMs,
      generation: generation,
      error: error,
    );
  }

  BasicMediaSessionAdapter buildAdapter({Duration? interval}) {
    return BasicMediaSessionAdapter(
      port: port,
      commands: commands,
      positionRefreshInterval: interval ?? const Duration(milliseconds: 1000),
      clock: () => now,
    );
  }

  setUp(() {
    port = _FakePort();
    commands = _FakeCommands();
    now = DateTime.utc(2026, 11, 16, 10);
  });

  group('real identity + real native readings', () {
    test('publishes the playing track and the native position verbatim', () async {
      final BasicMediaSessionAdapter adapter = buildAdapter();

      await adapter.sync(
        identity: track,
        audio: audio(playing: true, positionMs: 1234.4, durationMs: 244000),
      );

      expect(port.updates.length, 1);
      expect(port.updates.single.toMap(), <String, Object?>{
        'playing': true,
        'positionMs': 1234,
        'durationMs': 244000,
        'title': 'Blue Bird',
        'artist': 'Ikimono-gakari',
        'album': 'Blue Bird',
        'coverPath': '',
      });
      expect(adapter.published, isTrue);
      expect(adapter.lastError, isNull);

      await adapter.dispose();
    });

    test('never promotes buffering to playing', () async {
      final BasicMediaSessionAdapter adapter = buildAdapter();

      await adapter.sync(
        identity: track,
        audio: audio(buffering: true, playing: false, durationMs: 9000),
      );

      expect(port.updates.single.playing, isFalse);
      expect(port.updates.single.positionMs, 0);

      await adapter.dispose();
    });

    test('throttles position-only repeats but resends the latest real reading',
        () async {
      final BasicMediaSessionAdapter adapter = buildAdapter();
      await adapter.sync(
        identity: track,
        audio: audio(playing: true, positionMs: 1000, durationMs: 10000),
      );
      expect(port.updates.length, 1);

      now = now.add(const Duration(milliseconds: 999));
      await adapter.sync(
        identity: track,
        audio: audio(playing: true, positionMs: 1999, durationMs: 10000),
      );
      expect(port.updates.length, 1, reason: 'inside the refresh window');

      now = now.add(const Duration(milliseconds: 1));
      await adapter.sync(
        identity: track,
        audio: audio(playing: true, positionMs: 2999, durationMs: 10000),
      );
      expect(port.updates.length, 2);
      expect(port.updates.last.positionMs, 2999);

      await adapter.dispose();
    });

    test('publishes at once when a non-position field changes', () async {
      final BasicMediaSessionAdapter adapter = buildAdapter();
      await adapter.sync(
        identity: track,
        audio: audio(playing: true, positionMs: 1000, durationMs: 10000),
      );

      // 同一毫秒内：只有 playing 变了，节流不得吞掉它。
      await adapter.sync(
        identity: track,
        audio: audio(playing: false, positionMs: 1000, durationMs: 10000),
      );
      expect(port.updates.length, 2);
      expect(port.updates.last.playing, isFalse);

      // 只有时长变了（prepare 后 native 回读）也必须落地。
      await adapter.sync(
        identity: track,
        audio: audio(playing: false, positionMs: 1000, durationMs: 12000),
      );
      expect(port.updates.length, 3);
      expect(port.updates.last.durationMs, 12000);

      await adapter.sync(
        identity: track,
        audio: audio(playing: false, positionMs: 1000, durationMs: 12000),
      );
      expect(port.updates.length, 3, reason: 'identical state is not resent');

      await adapter.dispose();
    });

    test('publishes a new cover file path immediately', () async {
      final BasicMediaSessionAdapter adapter = buildAdapter();
      await adapter.sync(
        identity: track,
        audio: audio(playing: true, positionMs: 0, durationMs: 10000),
      );

      await adapter.sync(
        identity: const BasicMediaIdentity(
          id: 'siren:song:7',
          title: 'Blue Bird',
          artist: 'Ikimono-gakari',
          album: 'Blue Bird',
          coverFilePath: '/data/user/0/rhine/cache/cover_7.jpg',
        ),
        audio: audio(playing: true, positionMs: 0, durationMs: 10000),
      );

      expect(port.updates.length, 2);
      expect(port.updates.last.coverPath, '/data/user/0/rhine/cache/cover_7.jpg');

      await adapter.dispose();
    });

    test('ensureStarted resets the dedupe cache so the first sync lands',
        () async {
      final BasicMediaSessionAdapter adapter = buildAdapter();
      await adapter.sync(
        identity: track,
        audio: audio(playing: true, positionMs: 0, durationMs: 10000),
      );
      expect(port.updates.length, 1);

      expect(await adapter.ensureStarted(), isTrue);
      await adapter.sync(
        identity: track,
        audio: audio(playing: true, positionMs: 0, durationMs: 10000),
      );

      expect(port.calls, <String>['update', 'ensureStarted', 'update']);
      expect(port.updates.length, 2);

      await adapter.dispose();
    });
  });

  group('empty / error clears stale metadata and notification', () {
    test('null identity clears once and then stays quiet', () async {
      final BasicMediaSessionAdapter adapter = buildAdapter();
      await adapter.sync(
        identity: track,
        audio: audio(playing: true, positionMs: 500, durationMs: 10000),
      );

      await adapter.sync(identity: null, audio: audio());
      expect(port.calls.last, 'stop');
      expect(adapter.published, isFalse);
      expect(port.updates.length, 1, reason: 'clearing never publishes metadata');

      await adapter.sync(identity: null, audio: audio());
      expect(
        port.calls.where((String call) => call == 'stop').length,
        1,
        reason: 'a second clear is a no-op',
      );

      await adapter.dispose();
    });

    test('an identity with no real playing track is treated as empty', () async {
      final BasicMediaSessionAdapter adapter = buildAdapter();
      await adapter.sync(
        identity: track,
        audio: audio(playing: true, positionMs: 0, durationMs: 10000),
      );

      await adapter.sync(
        identity: const BasicMediaIdentity(id: '', title: ''),
        audio: audio(playing: true),
      );

      expect(port.calls.last, 'stop');
      expect(adapter.published, isFalse);

      await adapter.dispose();
    });

    test('a failed audio state is never reported as playing', () async {
      final BasicMediaSessionAdapter adapter = buildAdapter();

      await adapter.sync(
        identity: track,
        audio: audio(
          playing: true,
          positionMs: 3000,
          durationMs: 10000,
          error: 'prepare failed: 403',
        ),
      );

      expect(port.updates, isEmpty);
      expect(port.calls.contains('stop'), isFalse, reason: 'nothing was published yet');
      expect(adapter.published, isFalse);

      await adapter.dispose();
    });

    test('real playback restored after a clear publishes again', () async {
      final BasicMediaSessionAdapter adapter = buildAdapter();
      await adapter.sync(
        identity: track,
        audio: audio(playing: true, positionMs: 0, durationMs: 10000),
      );
      await adapter.sync(identity: null, audio: audio());
      expect(adapter.published, isFalse);

      await adapter.sync(
        identity: track,
        audio: audio(playing: true, positionMs: 700, durationMs: 10000),
      );

      expect(port.updates.length, 2);
      expect(port.updates.last.positionMs, 700);
      expect(adapter.published, isTrue);

      await adapter.dispose();
    });

    test('explicit stop always reaches the platform', () async {
      final BasicMediaSessionAdapter adapter = buildAdapter();

      await adapter.stop();

      expect(port.calls, <String>['stop']);
      expect(adapter.published, isFalse);

      await adapter.dispose();
    });

    test('sync after an explicit stop republishes the real state', () async {
      final BasicMediaSessionAdapter adapter = buildAdapter();
      await adapter.sync(
        identity: track,
        audio: audio(playing: false, positionMs: 0, durationMs: 10000),
      );
      await adapter.stop();

      await adapter.sync(
        identity: track,
        audio: audio(playing: false, positionMs: 0, durationMs: 10000),
      );

      expect(port.updates.length, 2);

      await adapter.dispose();
    });
  });

  group('ensureStarted honest reporting', () {
    test('is memoised and reports the accepted request', () async {
      final BasicMediaSessionAdapter adapter = buildAdapter();
      expect(adapter.started, isFalse);

      expect(await adapter.ensureStarted(), isTrue);
      expect(adapter.started, isTrue);
      expect(await adapter.ensureStarted(), isTrue);
      expect(port.calls, <String>['ensureStarted']);

      await adapter.dispose();
    });

    test('a rejected start is captured, not thrown', () async {
      final BasicMediaSessionAdapter adapter = buildAdapter();
      final PlatformException rejection = PlatformException(
        code: 'no_activity',
        message: 'ensureStarted requires a foreground Activity',
      );
      port.startFailure = rejection;

      expect(await adapter.ensureStarted(), isFalse);
      expect(adapter.started, isFalse);
      expect(adapter.lastError, same(rejection));

      await adapter.dispose();
    });

    test('a start the platform refuses is reported false, not as success',
        () async {
      final BasicMediaSessionAdapter adapter = buildAdapter();
      port.startAccepted = false;

      expect(await adapter.ensureStarted(), isFalse);
      expect(adapter.started, isFalse);
      expect(adapter.lastError, isNotNull);
      expect(port.updates, isEmpty);

      // 拒绝不能变成"待机通知"：状态缓存没被重置，也没有多出来的 update。
      expect(port.calls, <String>['ensureStarted']);

      // 之后真的能起来了，仍然可以重新请求并落地。
      port.startAccepted = true;
      expect(await adapter.ensureStarted(), isTrue);
      expect(adapter.started, isTrue);
      expect(adapter.lastError, isNull);

      await adapter.dispose();
    });

    test('a failed update stays unpublished and retries on the next sync',
        () async {
      final BasicMediaSessionAdapter adapter = buildAdapter();
      final PlatformException failure =
          PlatformException(code: 'not_foreground');
      port.updateFailure = failure;

      await adapter.sync(
        identity: track,
        audio: audio(playing: true, positionMs: 0, durationMs: 10000),
      );
      expect(adapter.lastError, same(failure));
      expect(adapter.published, isFalse);
      expect(port.updates, isEmpty);

      port.updateFailure = null;
      await adapter.sync(
        identity: track,
        audio: audio(playing: true, positionMs: 0, durationMs: 10000),
      );
      expect(adapter.published, isTrue);
      expect(port.updates.length, 1);

      await adapter.dispose();
    });
  });

  group('platform actions route to the existing authority', () {
    test('pause/resume/next/prev map onto the command funnel', () async {
      final BasicMediaSessionAdapter adapter = buildAdapter();

      port.emit('pause');
      port.emit('resume');
      port.emit('next');
      port.emit('prev');
      await pumpEventQueue();

      expect(commands.calls, <String>['pause', 'play', 'next', 'previous']);

      await adapter.dispose();
    });

    test('SEEK is clamped by the published real duration', () async {
      final BasicMediaSessionAdapter adapter = buildAdapter();
      await adapter.sync(
        identity: track,
        audio: audio(playing: true, positionMs: 0, durationMs: 200000),
      );

      port.emit('rhine.media.SEEK:50000');
      port.emit('rhine.media.SEEK:-1000');
      port.emit('rhine.media.SEEK:999999999');
      await pumpEventQueue();

      expect(commands.seeks, <double>[0.25, 0.0, 1.0]);

      await adapter.dispose();
    });

    test('SEEK is dropped when no real duration is known', () async {
      final BasicMediaSessionAdapter adapter = buildAdapter();
      await adapter.sync(
        identity: track,
        audio: audio(playing: true, positionMs: 0, durationMs: 0),
      );

      port.emit('rhine.media.SEEK:1500');
      port.emit('rhine.media.SEEK:abc');
      port.emit('rhine.media.SEEK:');
      await pumpEventQueue();

      expect(commands.seeks, isEmpty, reason: 'no duration -> no guess');

      await adapter.dispose();
    });

    test('unknown action strings are ignored', () async {
      final BasicMediaSessionAdapter adapter = buildAdapter();

      port.emit('rhine.media.stop');
      port.emit('pause ');
      port.emit('');
      await pumpEventQueue();

      expect(commands.calls, isEmpty);

      await adapter.dispose();
    });

    test('handling an action never writes the session back', () async {
      final BasicMediaSessionAdapter adapter = buildAdapter();
      await adapter.sync(
        identity: track,
        audio: audio(playing: true, positionMs: 1000, durationMs: 10000),
      );
      expect(port.updates.length, 1);

      port.emit('pause');
      port.emit('rhine.media.SEEK:5000');
      await pumpEventQueue();

      expect(port.updates.length, 1, reason: 'the real audio event drives sync');
      expect(commands.calls, <String>['pause', 'seek']);
      expect(commands.seeks, <double>[0.5]);

      await adapter.dispose();
    });

    test('a failing command is captured and never escapes the stream callback',
        () async {
      final BasicMediaSessionAdapter adapter = buildAdapter();
      final StateError failure = StateError('player busy');
      commands.failure = failure;

      port.emit('next');
      await pumpEventQueue();

      expect(adapter.lastError, same(failure));

      await adapter.dispose();
    });
  });

  group('dispose cuts the wiring', () {
    test('cancels actions, clears the published state and releases the port',
        () async {
      final BasicMediaSessionAdapter adapter = buildAdapter();
      await adapter.sync(
        identity: track,
        audio: audio(playing: true, positionMs: 0, durationMs: 10000),
      );
      expect(port.hasListener, isTrue);

      await adapter.dispose();

      expect(adapter.disposed, isTrue);
      expect(port.hasListener, isFalse, reason: 'no dangling action subscription');
      expect(port.calls.last, 'stop');
      expect(port.disposed, isTrue);

      await adapter.sync(
        identity: track,
        audio: audio(playing: true, positionMs: 1000, durationMs: 10000),
      );
      expect(port.updates.length, 1, reason: 'disposed adapter is inert');

      await adapter.dispose();
      expect(
        port.calls.where((String call) => call == 'stop').length,
        1,
        reason: 'dispose is idempotent',
      );
    });

    test('dispose without a publication does not stop the platform', () async {
      final BasicMediaSessionAdapter adapter = buildAdapter();

      await adapter.dispose();

      expect(port.calls, isEmpty);
      expect(port.disposed, isTrue);

      await adapter.dispose();
      expect(port.calls, isEmpty);
    });

    test('ensureStarted after dispose reports false without touching the port',
        () async {
      final BasicMediaSessionAdapter adapter = buildAdapter();
      await adapter.dispose();

      expect(await adapter.ensureStarted(), isFalse);
      expect(port.calls, isEmpty);
    });
  });

  // 静态文本守卫：只在磁盘源码上断言关键接口存在，防止实现回退；不是设备 PASS。
  group('late platform results never overwrite a newer truth', () {
    test('an update that returns after stop() does not republish the old state',
        () async {
      final BasicMediaSessionAdapter adapter = buildAdapter();
      port.updateGate = Completer<void>();

      final Future<void> inFlight = adapter.sync(
        identity: track,
        audio: audio(playing: true, positionMs: 500, durationMs: 10000),
      );
      await pumpEventQueue();
      expect(adapter.published, isFalse, reason: 'update 还没回来');

      // 用户在通知里按了停止/切走了：这条在飞的 update 属于上一代意图。
      await adapter.stop();
      port.updateGate!.complete();
      port.updateGate = null;
      await inFlight;

      expect(adapter.published, isFalse,
          reason: '晚回的 update 不能把已停止的通知重新点亮');
      expect(port.calls.where((String c) => c == 'stop'), isNotEmpty);

      await adapter.dispose();
    });

    test('a failed clear keeps the published state so the next sync can retry',
        () async {
      final BasicMediaSessionAdapter adapter = buildAdapter();
      await adapter.sync(
        identity: track,
        audio: audio(playing: true, durationMs: 10000),
      );
      expect(adapter.published, isTrue);

      port.stopFailure = StateError('backend busy');
      await adapter.sync(identity: null, audio: audio());
      expect(adapter.lastError, isNotNull);
      expect(adapter.published, isTrue,
          reason: '后端可能还留着旧通知：不能先抹掉去重记录、再也没人去清');

      port.stopFailure = null;
      await adapter.sync(identity: null, audio: audio());
      expect(adapter.published, isFalse);
      expect(port.calls.where((String c) => c == 'stop').length, 2);

      await adapter.dispose();
    });

    test('identity.id participates in dedupe: same text, different song republishes',
        () async {
      final BasicMediaSessionAdapter adapter = buildAdapter();
      const BasicMediaIdentity a = BasicMediaIdentity(
        id: 'siren:song:1',
        title: 'Same Title',
        artist: 'Same Artist',
        album: 'Same Album',
      );
      const BasicMediaIdentity b = BasicMediaIdentity(
        id: 'siren:song:2',
        title: 'Same Title',
        artist: 'Same Artist',
        album: 'Same Album',
      );

      await adapter.sync(identity: a, audio: audio(durationMs: 10000));
      await adapter.sync(identity: b, audio: audio(durationMs: 10000));

      expect(port.updates.length, 2,
          reason: '两首歌同名同封面也必须各报一次，否则通知停在上一首');

      await adapter.dispose();
    });
  });

  group('source guards (never a device PASS)', () {
    String readSource(String path) {
      final File file = File(path);
      expect(file.existsSync(), isTrue, reason: 'missing $path');
      return file.readAsStringSync();
    }

    test('the adapter owns no second player, channel handler or audio manager',
        () {
      final String source = readSource('lib/basic/basic_media_session.dart');

      expect(source, contains('class BasicMediaIdentity'));
      expect(source, contains('abstract interface class BasicMediaSessionCommands'));
      expect(source, contains('class BasicMediaSessionAdapter'));
      expect(source, contains("'rhine.media.SEEK:'"));
      expect(source, isNot(contains('MediaPlayer(')), reason: 'no second player');
      expect(source, isNot(contains('AudioManager')));
      expect(source, isNot(contains('setMethodCallHandler')));
      // 适配器不许自己开通道，只许通过 MediaSessionPort / 已存在的实现：
      // 断言构造式而不是 `new`（本仓库风格不用 new，断言 new 等于什么都没断言）。
      expect(source, isNot(contains('MethodChannel(')), reason: 'no own channel');
      expect(source, isNot(contains('EventChannel(')), reason: 'no own event channel');
    });

    test('the port contract stays disposable and documented', () {
      final String source = readSource('lib/platform/media_session.dart');

      expect(source, contains('abstract interface class MediaSessionPort'));
      expect(source, contains('Future<void> dispose();'));
      expect(source, contains('bool get isDisposed'));
      expect(source, contains('rhine.music.database/media_session'));
      expect(source, contains('rhine.music.database/media_session/events'));
    });

    test('the channel can be uninstalled without keeping the Activity closure',
        () {
      final String source = readSource(
        'android/app/src/main/kotlin/rhine/music/database/porting/MediaSessionChannel.kt',
      );

      expect(source, contains('fun uninstall('));
      expect(source, contains('MediaSessionHost.uninstall()'));
      expect(source, contains('setMethodCallHandler(null)'));
      expect(source, contains('setStreamHandler(null)'));
    });

    test('the host owns an uninstall and a shutdown path', () {
      final String source = readSource(
        'android/app/src/main/kotlin/rhine/music/database/porting/MediaSessionHost.kt',
      );

      expect(source, contains('fun uninstall()'));
      expect(source, contains('fun shutdown()'));
      expect(source, contains('clearMetadata()'));
      expect(source, contains('notifiedKey = ""'));
      expect(source, contains('commandSink = null'));
    });

    test('shutdown publishes the idle session before it stops the service', () {
      final String source = readSource(
        'android/app/src/main/kotlin/rhine/music/database/porting/MediaSessionHost.kt',
      );
      final int shutdownAt = source.indexOf('fun shutdown()');
      expect(shutdownAt, isNonNegative);

      final int publishAt = source.indexOf('instance?.publish()', shutdownAt);
      final int stopAt =
          source.indexOf('instance?.stopForHostShutdown()', shutdownAt);

      // 顺序就是契约：先让会话退成 STATE_STOPPED/actions=0，再撤通知停服务。
      // 反过来的话，释放播放器到 onDestroy 之间系统媒体面板还在展示会响应的播放/切歌键。
      expect(publishAt, isNonNegative);
      expect(stopAt, isNonNegative);
      expect(publishAt, lessThan(stopAt));
    });

    test('the service never advertises actions for an empty session', () {
      final String source = readSource(
        'android/app/src/main/kotlin/rhine/music/database/porting/MediaPlaybackService.kt',
      );

      expect(source, contains('STATE_STOPPED'));
      expect(source, contains('isIdle()'));
      expect(source, contains('stopForHostShutdown'));
      expect(source, contains('STOP_FOREGROUND_REMOVE'));
    });

    test('the media notification carries the real cover and compact controls', () {
      final String source = readSource(
        'android/app/src/main/kotlin/rhine/music/database/porting/MediaPlaybackService.kt',
      );

      // 封面必须挂到通知本身：会话元数据里的 ALBUM_ART 有些 ROM 不读，只认 setLargeIcon。
      // 钉「调用点 + 同一行的回收守卫」，而不是裸的 isRecycled——publish() 里本来就有一处，
      // 裸断言删掉通知侧守卫仍然绿。
      final int iconAt = source.indexOf('builder.setLargeIcon(');
      expect(iconAt, isNonNegative, reason: '通知必须把封面挂上去');
      final int iconLineStart = source.lastIndexOf('\n', iconAt);
      final int iconLineEnd = source.indexOf('\n', iconAt);
      final String iconLine = source.substring(
        iconLineStart < 0 ? 0 : iconLineStart,
        iconLineEnd < 0 ? source.length : iconLineEnd,
      );
      expect(
        iconLine,
        contains('!cover.isRecycled'),
        reason: 'setLargeIcon 必须带 isRecycled 守卫',
      );
      expect(source, contains('coverBitmap?.let'));

      // 紧凑态三键的索引必须和 action 的挂载条件同门。先把空白压平再断言：
      // ktlint 折行/缩进变化不会误伤，删掉 !isIdle() 条件则一定红。
      final String flat = source.replaceAll(RegExp(r'\s+'), ' ');
      expect(
        flat,
        contains('!MediaSessionHost.isIdle()) style.setShowActionsInCompactView('),
        reason: '三键索引必须条件挂载',
      );
    });

    test('the sole audio channel releases the player and session on uninstall',
        () {
      final String source = readSource(
        'android/app/src/main/kotlin/rhine/music/database/basic/BasicAudioChannel.kt',
      );

      expect(source, contains('MediaSessionChannel.uninstall()'));
      expect(source, contains('MediaSessionHost.shutdown()'));
      expect(source, contains('releaseForHostShutdown()'));
    });
  });
}

/// 记录平台调用的假端口；可注入失败，动作流可控。
class _FakePort implements MediaSessionPort {
  final List<String> calls = <String>[];
  final List<MediaSessionState> updates = <MediaSessionState>[];
  final StreamController<String> _actions = StreamController<String>.broadcast();

  Object? startFailure;
  Object? updateFailure;
  Object? stopFailure;

  /// 让 update 停在"已发出、还没回来"的状态，用来证明晚回值不覆盖更新的意图。
  Completer<void>? updateGate;
  bool disposed = false;

  /// 平台是否受理 ensureStarted（false = 被系统拒绝：无通知、无保活）。
  bool startAccepted = true;

  bool get hasListener => _actions.hasListener;

  void emit(String action) => _actions.add(action);

  @override
  Future<bool> ensureStarted() async {
    calls.add('ensureStarted');
    final Object? failure = startFailure;
    if (failure != null) {
      throw failure;
    }
    return startAccepted;
  }

  @override
  Future<void> update(MediaSessionState state) async {
    calls.add('update');
    final Completer<void>? gate = updateGate;
    if (gate != null) {
      await gate.future;
    }
    final Object? failure = updateFailure;
    if (failure != null) {
      throw failure;
    }
    updates.add(state);
  }

  @override
  Future<void> stop() async {
    calls.add('stop');
    final Object? failure = stopFailure;
    if (failure != null) {
      throw failure;
    }
  }

  @override
  Stream<String> get actions => _actions.stream;

  /// 通知封面的落盘目录：本文件不验证封面（返回 null = 不建缓存、不触网、
  /// 上报的 coverPath 恒为空），封面落盘由 user_scope_152_test.dart 用假
  /// HttpClient 单独证明。
  @override
  Future<String?> cacheDirectory() async => null;

  @override
  Future<void> dispose() async {
    disposed = true;
    if (!_actions.isClosed) {
      await _actions.close();
    }
  }
}

/// 记录系统动作落到既有播放权威的假实现。
class _FakeCommands implements BasicMediaSessionCommands {
  final List<String> calls = <String>[];
  final List<double> seeks = <double>[];
  Object? failure;

  Future<void> _record(String name) async {
    calls.add(name);
    final Object? error = failure;
    if (error != null) {
      throw error;
    }
  }

  @override
  Future<void> play() => _record('play');

  @override
  Future<void> pause() => _record('pause');

  @override
  Future<void> next() => _record('next');

  @override
  Future<void> previous() => _record('previous');

  @override
  Future<void> seekToFraction(double fraction) async {
    seeks.add(fraction);
    await _record('seek');
  }
}
