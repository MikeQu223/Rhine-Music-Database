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

/// 只为身份签名服务的目录替身（真实字段全给，避免测试构造半真对象）。
BasicDirectory _directory(String id) => BasicDirectory(
      provider: 'siren',
      kind: 'playlist',
      id: id,
      key: 'siren:playlist:$id',
      title: 'dir-$id',
      artist: '',
      cover: '',
      description: '',
      trackCount: 0,
      songs: const <SirenSong>[],
      ids: const <String>[],
      cursor: 0,
      index: 0,
    );

BasicViewState _state({
  BasicPhase phase = BasicPhase.library,
  SirenSong? song,
  List<SirenSong> songs = const <SirenSong>[],
  List<SirenAlbum> albums = const <SirenAlbum>[],
  bool dark = true,
  bool playing = false,
  List<List<BasicListItem>> laneItems = const <List<BasicListItem>>[],
  double? listPosition,
  BasicDirectory? directory,
}) =>
    BasicViewState(
      phase: phase,
      song: song,
      songs: songs,
      albums: albums,
      dark: dark,
      playing: playing,
      laneItems: laneItems,
      listPosition: listPosition,
      directory: directory,
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

  group('origin：输入/动作按 (viewId, ctx) 校验', () {
    test('ctx 不匹配的动作不交给页面；同 ctx 与未登记照常放行', () async {
      final List<String> delivered = <String>[];
      QtSceneActions.resetForTest();
      QtSceneActions.register(7, delivered.add);
      QtSceneActions.setContext(7, 3);

      // 旧代次（换目录前）的迟到动作：丢弃。
      await QtSceneActions.handleNativeCall(const MethodCall(
        'action',
        <String, Object?>{'viewId': 7, 'ctx': 2, 'action': 'archive-select:1|2|song|x'},
      ));
      expect(delivered, isEmpty);

      // 当前代次：正常送达。
      await QtSceneActions.handleNativeCall(const MethodCall(
        'action',
        <String, Object?>{'viewId': 7, 'ctx': 3, 'action': 'archive-scroll:commit:1.0'},
      ));
      expect(delivered, <String>['archive-scroll:commit:1.0']);

      // 老调用点不带 ctx：按旧行为放行（不能因为原生多知道一点就吞掉正常回执）。
      await QtSceneActions.handleNativeCall(const MethodCall(
        'action',
        <String, Object?>{'viewId': 7, 'action': 'archive-select:0:0'},
      ));
      expect(delivered.last, 'archive-select:0:0');

      // 未注册的 viewId 不抛、不下发。
      await QtSceneActions.handleNativeCall(const MethodCall(
        'action',
        <String, Object?>{'viewId': 99, 'ctx': 3, 'action': 'archive-select:0:0'},
      ));
      expect(delivered, hasLength(2));

      QtSceneActions.resetForTest();
    });
  });

  group('qtSceneIdentitySignature：只在集合身份变化时换代', () {
    test('拖动/惯性/选中变化不换代，换目录才换代', () {
      const BasicListItem item = BasicListItem(
        title: 'a',
        kind: 'song',
        index: 0,
        id: 'a',
        cover: 'https://cover/a.jpg',
      );
      final BasicViewState base = _state(
        songs: <SirenSong>[_song('a')],
        laneItems: const <List<BasicListItem>>[
          <BasicListItem>[item],
        ],
      );
      final BasicViewState scrolled = _state(
        song: _song('a'),
        songs: <SirenSong>[_song('a')],
        listPosition: 12.5,
        laneItems: const <List<BasicListItem>>[
          <BasicListItem>[item],
        ],
      );
      expect(qtSceneIdentitySignature(base), qtSceneIdentitySignature(scrolled));

      final BasicViewState otherDirectory = BasicViewState(
        phase: base.phase,
        songs: base.songs,
        laneItems: base.laneItems,
        directory: _directory('dir-1'),
      );
      expect(
        qtSceneIdentitySignature(otherDirectory),
        isNot(qtSceneIdentitySignature(base)),
      );
    });
  });

  group('qtSceneCellsOf：每格带自己的真实 metadata', () {
    test('c/a/b 来自本格源条目，不是选中项；空封面不带键', () {
      const BasicListItem withArt = BasicListItem(
        title: 'Song A',
        kind: 'song',
        index: 0,
        id: 'a',
        cover: 'https://cover/a.jpg',
        artist: 'Artist A',
        album: 'Album A',
        albumId: 'album-a',
      );
      const BasicListItem bare = BasicListItem(
        title: 'Song B',
        kind: 'song',
        index: 1,
        id: 'b',
      );
      final BasicViewState state = _state(
        laneItems: const <List<BasicListItem>>[
          <BasicListItem>[withArt, bare],
        ],
      );
      final List<Map<String, Object?>> cells = qtSceneCellsOf(state);
      expect(cells, isNotEmpty);
      final Map<String, Object?> first = cells.first;
      expect(first['k'], 'song');
      expect(first['i'], 'a');
      expect(first['c'], 'https://cover/a.jpg');
      expect(first['a'], 'Artist A');
      expect(first['b'], 'Album A');
      expect(first['r'], 0, reason: '绝对行：窗口基址 + 行');
      // 第 2 行是 bare：没有任何 metadata 键。
      final Map<String, Object?> second = cells[1];
      expect(second['i'], 'b');
      expect(second.containsKey('c'), isFalse);
      expect(second.containsKey('a'), isFalse);
      expect(second.containsKey('b'), isFalse);
    });
  });

  group('qtSceneStateSnapshot', () {
    test('有选中：带 index 与身份键，mode/dark 来自状态', () {
      final SirenSong a = _song('a');
      final Map<String, Object?> payload = _decode(qtSceneStateSnapshot(
        _state(phase: BasicPhase.detail, song: a, songs: <SirenSong>[a], dark: false),
      ));
      // v4：在 v3 的连续窗口（pos/lane）与 40 格语义槽位之上，加了
      // origin（view/ctx）与每格真实 metadata（c/a/b）。
      expect(payload['v'], 4);
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

    test('封面走选中身份的 URL，没有选中就没有 current（Qt 据此清旧图）', () {
      final SirenSong withCover = SirenSong(
        id: 'c',
        title: 'song-c',
        artist: 'artist',
        album: 'album',
        albumId: 'album-c',
        cover: 'https://hycdn.cn/cover/c.jpg',
        sourceUrl: '',
        lyricUrl: '',
        durationMs: 0,
      );
      final Map<String, Object?> payload = _decode(qtSceneStateSnapshot(
        _state(song: withCover, songs: <SirenSong>[withCover]),
      ));
      final Map<String, Object?> current =
          (payload['current']! as Map<Object?, Object?>).cast<String, Object?>();
      expect(current['kind'], 'song');
      expect(current['id'], 'c');
      expect(current['cover'], 'https://hycdn.cn/cover/c.jpg');

      final Map<String, Object?> none =
          _decode(qtSceneStateSnapshot(_state(songs: <SirenSong>[withCover])));
      expect(none.containsKey('current'), isFalse,
          reason: '没有选中时不能带上一个 current，否则 Qt 会继续显示上一首的封面');
    });

    test('歌曲自身没有封面时用同一张专辑的真实封面，取不到就诚实留空', () {
      SirenSong bare = SirenSong(
        id: 'n1',
        title: 'song-n1',
        artist: 'artist',
        album: 'album-n1',
        albumId: 'album-n1',
        cover: '',
        sourceUrl: '',
        lyricUrl: '',
        durationMs: 0,
      );
      SirenAlbum album = SirenAlbum(
        id: 'album-n1',
        name: 'album-n1',
        artist: 'artist',
        cover: 'https://hycdn.cn/cover/n1.jpg',
        songCount: 1,
        songs: const <SirenSong>[],
      );
      Map<String, Object?> payload = _decode(qtSceneStateSnapshot(
        _state(song: bare, songs: <SirenSong>[bare], albums: <SirenAlbum>[album]),
      ));
      Map<String, Object?> current =
          (payload['current']! as Map<Object?, Object?>).cast<String, Object?>();
      expect(current['cover'], 'https://hycdn.cn/cover/n1.jpg',
          reason: '塞壬 /api/songs 不保证带封面，专辑封面上是真实数据，不能因此留白');

      Map<String, Object?> miss =
          _decode(qtSceneStateSnapshot(_state(song: bare, songs: <SirenSong>[bare])));
      Map<String, Object?> missCurrent =
          (miss['current']! as Map<Object?, Object?>).cast<String, Object?>();
      expect(missCurrent['cover'], '',
          reason: '找不到专辑就只能空字符串：Qt 据此显示占位盘面，不能编一个 URL');
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
      // ctx 与写入快照的 ctx 是同一个值：原生用它给每个视图登记 origin。
      expect(
        calls.single.arguments,
        <String, Object?>{'viewId': 7, 'ctx': 0, 'json': '{"v":1}'},
      );
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
