// EXECUTION STATUS: NOT EXECUTED.
//
// This worktree forbids flutter test / dart test / build / analyze. The tests
// below are written for later execution with:
//
//   flutter test test/media_session_test.dart
//
// RED/GREEN are unknown until that command runs on a machine with the Flutter
// SDK. The source-contract test at the bottom reads committed source text, so
// it needs no engine or device.

import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rhine_music_database/platform/media_session.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const MethodChannel methodChannel =
      MethodChannel(mediaSessionMethodChannelName);
  const EventChannel eventChannel =
      EventChannel(mediaSessionEventChannelName);

  late List<MethodCall> calls;

  setUp(() {
    calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(methodChannel, (MethodCall call) async {
      calls.add(call);
      if (call.method == 'ensureStarted') {
        return true;
      }
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(methodChannel, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockStreamHandler(eventChannel, null);
  });

  group('MediaSessionState', () {
    test('serializes all seven fields and preserves null metadata', () {
      const MediaSessionState state = MediaSessionState(
        playing: true,
        positionMs: 1234,
        durationMs: 5678,
        title: 'Song',
        artist: 'Artist',
        album: 'Album',
        coverPath: '/tmp/cover.jpg',
      );

      expect(state.toMap(), <String, Object?>{
        'playing': true,
        'positionMs': 1234,
        'durationMs': 5678,
        'title': 'Song',
        'artist': 'Artist',
        'album': 'Album',
        'coverPath': '/tmp/cover.jpg',
      });

      const MediaSessionState empty = MediaSessionState(
        playing: false,
        positionMs: 0,
        durationMs: 0,
      );
      expect(empty.toMap(), <String, Object?>{
        'playing': false,
        'positionMs': 0,
        'durationMs': 0,
        'title': null,
        'artist': null,
        'album': null,
        'coverPath': null,
      });
    });

    test('rejects negative position and duration in debug mode', () {
      expect(
        () => MediaSessionState(
          playing: false,
          positionMs: -1,
          durationMs: 0,
        ),
        throwsAssertionError,
      );
      expect(
        () => MediaSessionState(
          playing: false,
          positionMs: 0,
          durationMs: -1,
        ),
        throwsAssertionError,
      );
    });

    test('is a value object', () {
      const MediaSessionState left = MediaSessionState(
        playing: true,
        positionMs: 1,
        durationMs: 2,
        title: 't',
      );
      const MediaSessionState right = MediaSessionState(
        playing: true,
        positionMs: 1,
        durationMs: 2,
        title: 't',
      );
      expect(left, right);
      expect(left.hashCode, right.hashCode);
    });
  });

  group('MethodChannelMediaSession', () {
    test('ensureStarted and stop each invoke exactly one method', () async {
      final MethodChannelMediaSession session = MethodChannelMediaSession();
      addTearDown(session.dispose);

      await session.ensureStarted();
      await session.stop();

      expect(calls.map((MethodCall call) => call.method).toList(),
          <String>['ensureStarted', 'stop']);
      expect(calls[0].arguments, isNull);
      expect(calls[1].arguments, isNull);
    });

    test('update sends exactly one call with the serialized state', () async {
      final MethodChannelMediaSession session = MethodChannelMediaSession();
      addTearDown(session.dispose);

      const MediaSessionState state = MediaSessionState(
        playing: true,
        positionMs: 42,
        durationMs: 100,
        title: 'Title',
        artist: 'Artist',
        album: 'Album',
        coverPath: '/c.jpg',
      );
      await session.update(state);

      expect(calls, hasLength(1));
      expect(calls.single.method, 'update');
      expect(calls.single.arguments, state.toMap());
    });

    test('actions are forwarded verbatim and never trigger outbound calls',
        () async {
      final MethodChannelMediaSession session = MethodChannelMediaSession();
      addTearDown(session.dispose);

      final _RecordingStreamHandler handler = _RecordingStreamHandler();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockStreamHandler(eventChannel, handler);

      final List<String> actions = <String>[];
      final StreamSubscription<String> subscription =
          session.actions.listen(actions.add);
      addTearDown(subscription.cancel);
      await pumpEventQueue();

      expect(handler.listens, 1);
      for (final String action in <String>[
        'pause',
        'resume',
        'next',
        'prev',
        'rhine.media.SEEK:1234',
      ]) {
        handler.emit(action);
      }
      await pumpEventQueue();

      expect(actions, <String>[
        'pause',
        'resume',
        'next',
        'prev',
        'rhine.media.SEEK:1234',
      ]);
      expect(calls, isEmpty,
          reason: 'actions are one-way; no update should be sent back');
    });

    test('actions broadcast to every listener and unsubscribe only once',
        () async {
      final MethodChannelMediaSession session = MethodChannelMediaSession();
      addTearDown(session.dispose);

      final _RecordingStreamHandler handler = _RecordingStreamHandler();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockStreamHandler(eventChannel, handler);

      final List<String> first = <String>[];
      final List<String> second = <String>[];
      final StreamSubscription<String> sub1 =
          session.actions.listen(first.add);
      final StreamSubscription<String> sub2 =
          session.actions.listen(second.add);
      await pumpEventQueue();

      expect(handler.listens, 1);
      handler.emit('pause');
      await pumpEventQueue();
      expect(first, <String>['pause']);
      expect(second, <String>['pause']);

      await sub1.cancel();
      await pumpEventQueue();
      expect(handler.cancels, 0);

      await sub2.cancel();
      await pumpEventQueue();
      expect(handler.cancels, 1);
    });

    test('dispose cancels the subscription, closes the stream, and rejects use',
        () async {
      final MethodChannelMediaSession session = MethodChannelMediaSession();
      final _RecordingStreamHandler handler = _RecordingStreamHandler();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockStreamHandler(eventChannel, handler);

      final StreamSubscription<String> subscription =
          session.actions.listen((String _) {});
      await pumpEventQueue();
      expect(handler.listens, 1);

      await session.dispose();
      expect(handler.cancels, 1);
      expect(() => session.actions, throwsStateError);
      await expectLater(session.stop(), throwsStateError);
      expect(calls, isEmpty, reason: 'dispose must not leave an outbound call');
      await subscription.cancel();
    });

    test('Kotlin channel names and MainActivity registration stay in sync', () {
      final String kotlin = File(
        'android/app/src/main/kotlin/rhine/music/database/porting/MediaSessionChannel.kt',
      ).readAsStringSync();
      final String activity = File(
        'android/app/src/main/kotlin/rhine/music/database/MainActivity.kt',
      ).readAsStringSync();

      expect(
        kotlin,
        contains(
          'const val METHOD_CHANNEL = "rhine.music.database/media_session"',
        ),
      );
      expect(
        kotlin,
        contains(
          'const val EVENT_CHANNEL = "rhine.music.database/media_session/events"',
        ),
      );
      expect(kotlin, contains('activityProvider: () -> Activity?'));
      expect(kotlin, contains('MediaSessionHost.install(appContext)'));
      expect(kotlin, contains('"no_activity"'));

      final int superIndex =
          activity.indexOf('super.configureFlutterEngine(flutterEngine)');
      final int installIndex =
          activity.indexOf('MediaSessionChannel.install(');
      expect(superIndex, greaterThanOrEqualTo(0));
      expect(installIndex, greaterThan(superIndex));
    });
  });
}

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

  void emit(String action) {
    final MockStreamHandlerEventSink? sink = _sink;
    if (sink != null) {
      sink.success(action);
    }
  }
}
