import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rhine_music_database/basic/basic_models.dart';
import 'package:rhine_music_database/basic/qt_scene_view.dart';

/// Qt 场景视图的契约测试（NATIVE-RECOVERY-132R）。
///
/// 只测 Dart 侧能证明的东西：快照词表、身份键的"无选中即无键"、通道下发与去重、
/// 原生动作按 viewId 分发。Qt 的旋转/归档几何不在这里假装验证——那要实机日志。
SirenSong _song(String id, {String title = ''}) => SirenSong(
      id: id,
      title: title.isEmpty ? 'song-$id' : title,
      artist: 'artist',
      album: 'album',
      albumId: 'album-$id',
      cover: '',
      sourceUrl: '',
      lyricUrl: '',
      durationMs: 0,
    );

BasicViewState _state({
  BasicPhase phase = BasicPhase.library,
  SirenSong? song,
  List<SirenSong> songs = const <SirenSong>[],
  bool dark = true,
  bool playing = false,
}) =>
    BasicViewState(
      phase: phase,
      song: song,
      songs: songs,
      dark: dark,
      playing: playing,
    );

Map<String, Object?> _decode(String snapshot) =>
    jsonDecode(snapshot) as Map<String, Object?>;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('qtSceneModeOf', () {
    test('library/boot → archive, detail/lyrics → detail', () {
      expect(qtSceneModeOf(_state()), 'archive');
      expect(qtSceneModeOf(_state(phase: BasicPhase.boot)), 'archive');
      expect(qtSceneModeOf(_state(phase: BasicPhase.detail)), 'detail');
      expect(qtSceneModeOf(_state(phase: BasicPhase.lyrics)), 'detail');
    });
  });

  group('qtSceneSelectedIndexOf', () {
    test('选中曲目在可见列表里的行号', () {
      final SirenSong a = _song('a');
      final SirenSong b = _song('b');
      expect(
        qtSceneSelectedIndexOf(_state(song: b, songs: <SirenSong>[a, b])),
        1,
      );
    });

    test('没有选中 / 选中不在列表里 → -1', () {
      expect(qtSceneSelectedIndexOf(_state()), -1);
      expect(
        qtSceneSelectedIndexOf(_state(song: _song('x'), songs: <SirenSong>[_song('a')])),
        -1,
      );
    });
  });

  group('qtSceneStateSnapshot', () {
    test('有选中：带 index 与身份键，mode/dark 来自状态', () {
      final SirenSong a = _song('a');
      final Map<String, Object?> payload = _decode(qtSceneStateSnapshot(
        _state(phase: BasicPhase.detail, song: a, songs: <SirenSong>[a], dark: false),
      ));
      expect(payload['v'], 1);
      expect(payload['dark'], isFalse);
      expect(payload['mode'], 'detail');
      expect(payload['index'], 0);
      expect(payload['key'], 'siren:song:a');
      expect(payload['count'], 1);
    });

    test('无选中：不带 key（Qt 侧据此清掉旧封面），index=-1', () {
      final Map<String, Object?> payload =
          _decode(qtSceneStateSnapshot(_state(songs: <SirenSong>[_song('a')])));
      expect(payload.containsKey('key'), isFalse);
      expect(payload['index'], -1);
      expect(payload['mode'], 'archive');
    });

    test('播放状态不进快照：playing 不影响 payload（不冒充播放/不推播放指令）', () {
      final SirenSong a = _song('a');
      final String idle = qtSceneStateSnapshot(_state(song: a, songs: <SirenSong>[a]));
      final String playing =
          qtSceneStateSnapshot(_state(song: a, songs: <SirenSong>[a], playing: true));
      expect(playing, idle);
    });
  });

  group('QtSceneStateSender', () {
    late List<MethodCall> calls;
    late QtSceneStateSender sender;

    setUp(() {
      calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel(qtSceneChannelName), (MethodCall call) async {
        calls.add(call);
        return null;
      });
      sender = QtSceneStateSender();
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel(qtSceneChannelName), null);
    });

    test('下发 state：带 viewId 与 json', () async {
      final bool sent = await sender.push(7, '{"v":1}');
      expect(sent, isTrue);
      expect(calls, hasLength(1));
      expect(calls.single.method, 'state');
      expect(calls.single.arguments, <String, Object?>{'viewId': 7, 'json': '{"v":1}'});
    });

    test('同一份快照不重复发；内容变了再发', () async {
      expect(await sender.push(7, '{"v":1}'), isTrue);
      expect(await sender.push(7, '{"v":1}'), isFalse);
      expect(await sender.push(7, '{"v":2}'), isTrue);
      expect(calls, hasLength(2));
    });

    test('forget 之后同一份快照会重发（重进页面时 Qt 侧需要重新拿到状态）', () async {
      expect(await sender.push(3, '{"v":1}'), isTrue);
      sender.forget(3);
      expect(await sender.push(3, '{"v":1}'), isTrue);
      expect(calls, hasLength(2));
    });

    test('原生回 false（未受理）时清掉去重，下一份同样的快照还会重发', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel(qtSceneChannelName), (MethodCall call) async {
        calls.add(call);
        return false;
      });

      expect(await sender.push(9, '{"v":1}'), isFalse);
      expect(await sender.push(9, '{"v":1}'), isFalse);
      // 两次都真的发出去了：第一次被拒后记录已清，同一份快照不会被永久吞掉。
      expect(calls, hasLength(2));
    });
  });

  group('QtSceneActions', () {
    tearDown(QtSceneActions.resetForTest);

    test('原生 action 按 viewId 分发给对应回调', () async {
      final List<String> got = <String>[];
      QtSceneActions.register(11, got.add);
      QtSceneActions.register(12, (String action) => got.add('12:$action'));

      await QtSceneActions.handleNativeCall(const MethodCall(
        'action',
        <String, Object?>{'viewId': 12, 'action': 'select:3'},
      ));
      await QtSceneActions.handleNativeCall(const MethodCall(
        'action',
        <String, Object?>{'viewId': 11, 'action': 'viewer:open'},
      ));
      expect(got, <String>['12:select:3', 'viewer:open']);
    });

    test('未知 viewId / 未注册回调不抛异常', () async {
      await QtSceneActions.handleNativeCall(const MethodCall(
        'action',
        <String, Object?>{'viewId': 99, 'action': 'select:1'},
      ));
      QtSceneActions.unregister(99);
    });
  });

  group('QtSceneView', () {
    test('QtSceneView 构造契约：state 必填，onAction/onCreated 可选', () {
      final QtSceneView view = QtSceneView(state: _state());
      expect(view.state.phase, BasicPhase.library);
      expect(view.onAction, isNull);
      expect(view.onCreated, isNull);
    });

    testWidgets('非 Android 平台渲染显式占位，不伪造 3D', (WidgetTester tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      try {
        await tester.pumpWidget(MaterialApp(
          home: Builder(builder: (BuildContext context) {
            return QtSceneView(state: _state(), onAction: (String _) {});
          }),
        ));
        expect(find.byType(QtSceneUnsupported), findsOneWidget);
        expect(find.textContaining('3D 场景预览仅在 Android 可用'), findsOneWidget);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });
  });
}
