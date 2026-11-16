// 双向连续滚动 + 冷启动封面闭合（FINAL-INTEGRATION-141）。
//
// 用户 m01578 的两条 P0 原话：
//   1) 列表或者 3D 层被滚动时另一方没有同步滚动；
//   2) 封面还是不加载。
//
// 本文件钉住的是**同一份窗口真值**的两半，而不是两半各自自证：
//   * Flutter → Qt：state.listPosition（条目，可为小数）经 qtSceneStateSnapshot 的
//     `pos`/`lane`/`cells` 投影过去，3D 在拖动**中途**就跟着滚；
//   * Qt → Flutter：Qt 的 archive 轨道位置折成条目增量，经 `archive-scroll:*` 回执
//     落到同一个 _listPosition 上（拖动/惯性每帧，松手才 commit 落行选中）；
//   * 冷启动：曲库到位即默认选中第一行（Qt 一进库 current 就有值），否则 Qt 收到的
//     永远是 index=-1/key=（真机 06:28:28 的 RHINE_QT_SCENE_STATE），
//     prefetchCover 一次都不会被调用 —— 这就是"封面不加载"的根因。
//
// 真机侧还要证明的是像素与纹理（RHINE_QT_COVER_REQUEST/RESULT/READY + 盘面像素），
// widget 测试只能证明状态/协议这一段；文件里不把两者混着说。

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rhine_music_database/basic/basic_app.dart';
import 'package:rhine_music_database/basic/basic_hud_resources.dart';
import 'package:rhine_music_database/basic/basic_models.dart';
import 'package:rhine_music_database/basic/platform_playback.dart';
import 'package:rhine_music_database/basic/qt_scene_view.dart';
import 'package:rhine_music_database/basic/siren_controller.dart';
import 'package:rhine_music_database/basic/siren_repository.dart';

/// 只记录调用、不出声的音频端口。
class _RecordingAudio implements BasicAudioPort {
  final List<String> calls = <String>[];
  final List<void Function(BasicAudioState)> _listeners =
      <void Function(BasicAudioState)>[];
  final BasicAudioState _state = BasicAudioState.idle;

  @override
  BasicAudioState get state => _state;

  @override
  void addListener(void Function(BasicAudioState) listener) =>
      _listeners.add(listener);

  @override
  void removeListener(void Function(BasicAudioState) listener) =>
      _listeners.remove(listener);

  @override
  Future<void> prepare(String url, {required int generation}) async {
    calls.add('prepare:$url:$generation');
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
    calls.add('seek:$positionMs:$generation');
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

SirenHttpResult _json(Object? body) {
  return SirenHttpResult(statusCode: 200, bytes: utf8.encode(jsonEncode(body)));
}

/// 真实 wire 形状的曲库（/api/songs + /api/albums + /api/song），不发网络请求。
SirenRepository _repository(List<String> songs) {
  return SirenRepository(
    get: (Uri uri) async {
      switch (uri.path) {
        case '/api/songs':
          return _json(<String, Object?>{
            'code': 0,
            'data': <Object?>[
              for (final String id in songs)
                <String, Object?>{
                  'cid': id,
                  'name': 'Song $id',
                  'albumCid': 'a1',
                  'artists': <Object?>['歌手甲'],
                },
            ],
          });
        case '/api/albums':
          return _json(<String, Object?>{
            'code': 0,
            'data': <Object?>[
              <String, Object?>{
                'cid': 'a1',
                'name': 'Album One',
                'coverUrl': 'https://cover.test/a1.jpg',
                'artistes': <Object?>['歌手甲'],
              },
            ],
          });
        case '/api/song':
          return _json(<String, Object?>{
            'code': 200,
            'value': <String, Object?>{
              'cid': uri.queryParameters['cid'],
              'name': 'Song',
              'albumCid': 'a1',
              'sourceUrl': 'https://file.test/song.flac',
              'lyricUrl': '',
              'artists': <Object?>['歌手甲'],
            },
          });
        default:
          return _json(<String, Object?>{'code': 0, 'data': const <Object?>[]});
      }
    },
  );
}

/// 字形表桩：{light:{...}}，字体文件一律缺失（与 runtime_startup_test 同款）。
class _StubBundle extends AssetBundle {
  static const String _glyphTable =
      '{"light":{"units":1000,"ascent":1044,"descent":-282,"glyphs":{}}}';

  @override
  Future<ByteData> load(String key) async {
    throw FlutterError('测试资源包没有字体文件 $key');
  }

  @override
  Future<String> loadString(String key, {bool cache = true}) async {
    if (key == basicGlyphTableAsset) {
      return _glyphTable;
    }
    if (key == basicLetteringAsset) {
      return '{}';
    }
    throw FlutterError('测试资源包缺少 $key');
  }
}

BasicListItem _item(String kind, int index, String id, String title) =>
    BasicListItem(title: title, kind: kind, index: index, id: id);

BasicViewState _stateWithLanes({
  required List<List<BasicListItem>> lanes,
  List<int>? offsets,
  int lane = 3,
  double pos = 0,
  SirenSong? song,
}) {
  return BasicViewState(
    phase: BasicPhase.library,
    songs: const <SirenSong>[],
    selectedLane: lane,
    listPosition: pos,
    laneItems: lanes,
    laneOffsets: offsets ?? const <int>[0, 0, 0, 0, 0],
    song: song,
  );
}

Map<String, Object?> _decode(String raw) =>
    jsonDecode(raw) as Map<String, Object?>;

void main() {
  group('快照 v3：连续窗口 + 40 格语义槽位', () {
    test('cells 有界（≤5×8）且带真实 kind+id，空列不产生占位', () {
      final List<BasicListItem> lane3 = <BasicListItem>[
        for (int i = 0; i < 12; i++) _item('song', i, 's$i', 'Song $i'),
      ];
      final BasicViewState state = _stateWithLanes(
        lanes: <List<BasicListItem>>[
          const <BasicListItem>[], // 0 搜索结果：空
          <BasicListItem>[_item('song', 0, 'l1', 'Liked')],
          const <BasicListItem>[], // 2 我的歌单：空
          lane3,
          <BasicListItem>[_item('album', 0, 'a1', 'Album One')],
        ],
      );
      final List<Map<String, Object?>> cells = qtSceneCellsOf(state);
      expect(cells.length, lessThanOrEqualTo(qtSceneLaneCount * qtScenePhysicalRows));
      // 空列整列不产生条目：0 列与 2 列都不在表里。
      expect(cells.where((Map<String, Object?> c) => c['l'] == 0), isEmpty);
      expect(cells.where((Map<String, Object?> c) => c['l'] == 2), isEmpty);
      // 有内容的列是 8 行，且身份是条目的真实 id（不是行号）。
      final List<Map<String, Object?>> lane3Cells =
          cells.where((Map<String, Object?> c) => c['l'] == 3).toList();
      expect(lane3Cells.length, qtScenePhysicalRows);
      expect(lane3Cells.first['k'], 'song');
      expect(lane3Cells.first['i'], 's0');
      expect(lane3Cells[1]['i'], 's1');
      expect(lane3Cells.first['r'], 0);
      expect(lane3Cells.last['r'], 7);
    });

    test('负 offset 按 Qt 的 wrap 语义回列表内（不夹平、不造占位）', () {
      final List<BasicListItem> lane4 = <BasicListItem>[
        for (int i = 0; i < 10; i++) _item('album', i, 'a$i', 'Album $i'),
      ];
      // 负 offset 属于 HUD 记忆：只有**非当前列**还用记忆值（当前列的基址跟随连续
      // pos）。Qt MusicLibrary.cpp:646-667 的 next() 会算出 -2 = 从倒数第二条起。
      final BasicViewState state = _stateWithLanes(
        lane: 3,
        lanes: <List<BasicListItem>>[
          const <BasicListItem>[],
          const <BasicListItem>[],
          const <BasicListItem>[],
          const <BasicListItem>[],
          lane4,
        ],
        offsets: const <int>[0, 0, 0, 0, -2],
      );
      final List<Map<String, Object?>> cells = qtSceneCellsOf(state);
      expect(cells.length, qtScenePhysicalRows);
      // -2 % 10 → 8；-1 → 9；0 → 0
      expect(cells[0]['i'], 'a8');
      expect(cells[1]['i'], 'a9');
      expect(cells[2]['i'], 'a0');
    });

    test('快照带 pos/lane 让 3D 在拖动中途就能滚（不是松手才动）', () {
      final BasicViewState state = _stateWithLanes(
        lanes: <List<BasicListItem>>[
          const <BasicListItem>[],
          const <BasicListItem>[],
          const <BasicListItem>[],
          <BasicListItem>[_item('song', 0, 's0', 'Song 0')],
          const <BasicListItem>[],
        ],
        pos: 12.5,
        lane: 3,
      );
      final Map<String, Object?> payload = _decode(qtSceneStateSnapshot(state));
      expect(payload['v'], 3);
      expect(payload['pos'], 12.5);
      expect(payload['lane'], 3);
      expect(payload['cells'], isA<List<Object?>>());
    });

    test('qtSceneRowOfCell 只对当前列成立；别的列返回 null（不猜下标）', () {
      final List<BasicListItem> lane3 = <BasicListItem>[
        for (int i = 0; i < 10; i++) _item('song', i, 's$i', 'Song $i'),
      ];
      final BasicViewState state = _stateWithLanes(
        lanes: <List<BasicListItem>>[
          const <BasicListItem>[],
          const <BasicListItem>[],
          const <BasicListItem>[],
          lane3,
          const <BasicListItem>[],
        ],
        offsets: const <int>[0, 0, 0, -2, 0],
      );
      // 绝对行域：场景行 = 12 + 条目，与窗口位置无关（行 12 永远是条目 0）。
      expect(qtSceneRowOfCell(state, const QtSceneCellRef(3, 12)), 0);
      expect(qtSceneRowOfCell(state, const QtSceneCellRef(3, 14)), 2);
      expect(qtSceneRowOfCell(state, const QtSceneCellRef(1, 12)), isNull);
      // pos 推到 14 时基址变成 (14~/8)*8 = 8：同一物理行折出不同条目——这就是
      // "窗口动了、几何行没动"的真实语义。
      final BasicViewState moved = _stateWithLanes(
        lanes: <List<BasicListItem>>[
          const <BasicListItem>[],
          const <BasicListItem>[],
          const <BasicListItem>[],
          lane3,
          const <BasicListItem>[],
        ],
        offsets: const <int>[0, 0, 0, -2, 0],
        pos: 14,
      );
      // 窗口滚到 pos=14 以后，原来的"行 12"已经不在视野里；几何折行只看绝对行，
      // 视野里的前排是场景行 12+14=26（= 条目 14）。
      // 这一列只有 10 条，所以折行按 Qt 的 wrap 语义取模（14 % 10 = 4）。
      expect(qtSceneRowOfCell(moved, const QtSceneCellRef(3, 26)), 4);
      expect(qtSceneRowOfCell(moved, const QtSceneCellRef(3, 28)), 6);
    });

    test('拖动后 pos≠offset：折行基准必须跟随连续位置（审查 MUST-5 反例）', () {
      final List<BasicListItem> lane3 = <BasicListItem>[
        for (int i = 0; i < 300; i++) _item('song', i, 's$i', 'Song $i'),
      ];
      // HUD 记忆仍是上次松手的 8 倍数窗口（-2），但连续真值已经推到 87。
      final BasicViewState state = _stateWithLanes(
        lanes: <List<BasicListItem>>[
          const <BasicListItem>[],
          const <BasicListItem>[],
          const <BasicListItem>[],
          lane3,
          const <BasicListItem>[],
        ],
        offsets: const <int>[0, 0, 0, -2, 0],
        pos: 87,
      );
      // 审查 MUST-1' 的反例：pos=87 时原生拾取的前排是绝对行 92..99，
      // 折回必须是 80..87（旧实现会给出 160..167）。
      expect(qtSceneRowOfCell(state, const QtSceneCellRef(3, 92)), 80);
      expect(qtSceneRowOfCell(state, const QtSceneCellRef(3, 99)), 87);
      expect(qtSceneRowOfCell(state, const QtSceneCellRef(3, 12)),
          isNot(equals(8)),
          reason: '不能退回 8 倍数记忆值');
    });

    test('身份优先：带 kind+id 回传时按身份折行，窗口移动也指向同一条（MUST-4）', () {
      final List<BasicListItem> lane3 = <BasicListItem>[
        for (int i = 0; i < 300; i++) _item('song', i, 's$i', 'Song $i'),
      ];
      final BasicViewState state = _stateWithLanes(
        lanes: <List<BasicListItem>>[
          const <BasicListItem>[],
          const <BasicListItem>[],
          const <BasicListItem>[],
          lane3,
          const <BasicListItem>[],
        ],
        offsets: const <int>[0, 0, 0, 0, 0],
        pos: 87,
      );
      // 同一条目 s50：几何上物理行 12 现在指 80，但身份回传必须折回 50。
      expect(
        qtSceneRowOfCell(
            state, const QtSceneCellRef(3, 12, kind: 'song', id: 's50')),
        50,
      );
      // 身份不在这一列（编造 id）时退化到几何（绝对行 92 - 12 = 80），不是 null/-1。
      expect(
        qtSceneRowOfCell(
            state, const QtSceneCellRef(3, 92, kind: 'song', id: 'nope')),
        80,
      );
      // 线上格式（原生带身份回传）：archive-select:<lane>|<row>|<kind>|<id>
      final QtSceneCellRef? parsed =
          QtSceneCellRef.parse('archive-select:3|12|song|siren:song:880380');
      expect(parsed?.lane, 3);
      expect(parsed?.row, 12);
      expect(parsed?.kind, 'song');
      expect(parsed?.id, 'siren:song:880380', reason: 'id 里允许出现冒号');
      expect(QtSceneCellRef.parse('archive-select:3:12')?.kind, isNull);
    });
  });

  group('archive-scroll 回执解析（Qt → Flutter）', () {
    test('start / move / commit 三类，以及非回执/坏格式一律 null', () {
      final QtSceneScrollEvent? start =
          QtSceneScrollEvent.parse('archive-scroll:start:0.000');
      expect(start?.started, isTrue);
      expect(start?.committed, isFalse);

      final QtSceneScrollEvent? move =
          QtSceneScrollEvent.parse('archive-scroll:move:-3.500');
      expect(move?.deltaRows, -3.5);
      expect(move?.started, isFalse);

      final QtSceneScrollEvent? commit =
          QtSceneScrollEvent.parse('archive-scroll:commit:7.250');
      expect(commit?.committed, isTrue);
      expect(commit?.deltaRows, 7.25);

      expect(QtSceneScrollEvent.parse('music:open'), isNull);
      expect(QtSceneScrollEvent.parse('archive-scroll:move'), isNull);
      expect(QtSceneScrollEvent.parse('archive-scroll:move:1:2'), isNull);
    });

    test('cell 回执解析：archive-select:<lane>:<row>', () {
      final QtSceneCellRef? cell = QtSceneCellRef.parse('archive-select:3:15');
      expect(cell?.lane, 3);
      expect(cell?.row, 15);
      expect(QtSceneCellRef.parse('archive-select:3'), isNull);
      expect(QtSceneCellRef.parse('archive-scroll:start:0'), isNull);
    });
  });

  group('controller：一份窗口真值（更新不落行，落行不改播放）', () {
    test('updateLibraryScroll 只写 listPosition：选中/播放/队列都不动', () async {
      final _RecordingAudio audio = _RecordingAudio();
      final BasicController controller = BasicController(
        audio: audio,
        repository: _repository(<String>['s1', 's2', 's3']),
      );
      addTearDown(controller.dispose);
      await controller.boot();
      final String? selectionBefore = controller.state.selection?.id;
      final int queueBefore = controller.state.queue.length;

      controller.updateLibraryScroll(2.5);
      expect(controller.state.listPosition, 2.5);
      expect(controller.state.selection?.id, selectionBefore, reason: '拖动中途不改选中');
      expect(controller.state.queue.length, queueBefore);
      expect(audio.calls.where((String c) => c.startsWith('play')), isEmpty);
      expect(audio.calls.where((String c) => c.startsWith('prepare')), isEmpty);

      // 同一个位置再写一次是 no-op（防回声/防重复投影）。
      controller.updateLibraryScroll(2.5);
      expect(controller.state.listPosition, 2.5);
    });

    test('applyNativeArchiveScroll：start 记原点、move 连续、commit 才落行', () async {
      final _RecordingAudio audio = _RecordingAudio();
      final BasicController controller = BasicController(
        audio: audio,
        repository: _repository(<String>['s1', 's2', 's3', 's4', 's5']),
      );
      addTearDown(controller.dispose);
      await controller.boot();

      controller.applyNativeArchiveScroll(0, started: true);
      controller.applyNativeArchiveScroll(1.4);
      expect(controller.state.listPosition, closeTo(1.4, 1e-9));
      expect(controller.state.selection?.id, 's1', reason: '拖动中途不落行（仍是最初选中）');

      controller.applyNativeArchiveScroll(2.6);
      expect(controller.state.listPosition, closeTo(2.6, 1e-9));
      expect(controller.state.selection?.id, 's1');

      // 松手：落到最近一行（3 = s4），仍然只是选中，不 prepare/不 play/不改队列。
      controller.applyNativeArchiveScroll(2.6, committed: true);
      await Future<void>.delayed(Duration.zero);
      expect(controller.state.selection?.id, 's4');
      expect(controller.state.listPosition, 3.0);
      expect(controller.state.playing, isFalse);
      expect(audio.calls.where((String c) => c.startsWith('play')), isEmpty);
      expect(audio.calls.where((String c) => c.startsWith('prepare')), isEmpty);
      expect(controller.state.queue, isEmpty, reason: '3D 滚动不建队列');
    });

    test('回执夹在列表范围内，不会越界', () async {
      final _RecordingAudio audio = _RecordingAudio();
      final BasicController controller = BasicController(
        audio: audio,
        repository: _repository(<String>['s1', 's2', 's3']),
      );
      addTearDown(controller.dispose);
      await controller.boot();

      controller.applyNativeArchiveScroll(0, started: true);
      controller.applyNativeArchiveScroll(99);
      expect(controller.state.listPosition, 2.0, reason: '夹到最后一行的条目位置');
      controller.applyNativeArchiveScroll(-99);
      expect(controller.state.listPosition, 0.0);
    });
  });

  group('原生点选身份 → 列表行（archive-select 的消费端）', () {
    test('带身份的格回传折回真实行；别列/无身份不猜行', () async {
      final _RecordingAudio audio = _RecordingAudio();
      final BasicController controller = BasicController(
        audio: audio,
        repository: _repository(<String>['s1', 's2', 's3', 's4', 's5']),
      );
      addTearDown(controller.dispose);
      await controller.boot();
      // BasicApp._onAction 的做法：解析原生回传 → 折行 → selectLibraryRow(row)。
      final BasicViewState state = controller.state;
      expect(state.selectedLane, 3, reason: '默认落在全部歌曲列');
      expect(state.laneItems.length, 5);
      expect(state.laneItems[3].length, 5);

      // 身份回传（原生从 cells 里查到的 kind+id）→ 该条目的真实行，即使几何行不同。
      final QtSceneCellRef identity =
          QtSceneCellRef.parse('archive-select:3|17|song|s4')!;
      final int? row = qtSceneRowOfCell(state, identity);
      expect(row, 3, reason: 's4 是第 4 行（0 基 3）');
      await controller.selectLibraryRow(row!);
      expect(controller.state.selection?.id, 's4');

      // 别列的格：当前窗口没有它，返回 null（调用方不猜行，原生会还原选中）。
      expect(qtSceneRowOfCell(controller.state, const QtSceneCellRef(1, 12)), isNull);
      // 纯几何回传：pos=3 时基址 0，物理行 13 → 行 1。
      expect(qtSceneRowOfCell(controller.state, const QtSceneCellRef(3, 13)), 1);
      expect(audio.calls.where((String c) => c.startsWith('play')), isEmpty,
          reason: '点选只改选中，不自动播放');
    });
  });

  group('真实 BasicApp 接线（用户 P0 #1/#2 的软件侧闭合）', () {
    testWidgets('冷启动曲库到位即默认选中第一行，快照带 current(cover)/index/pos',
        (WidgetTester tester) async {
      final _RecordingAudio audio = _RecordingAudio();
      final BasicController controller = BasicController(
        audio: audio,
        repository: _repository(<String>['s1', 's2', 's3']),
      );
      await tester.pumpWidget(BasicApp(
        controller: controller,
        audio: audio,
        bundle: _StubBundle(),
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(controller.state.catalogLoaded, isTrue);
      expect(controller.state.songs.length, 3);
      // 默认选中：Qt 侧 current/music 因此拿得到身份与封面 URL。
      expect(controller.state.song?.id, 's1');
      expect(controller.state.selection?.id, 's1');
      // 首屏状态文案仍是曲库规模（不被"已选中"盖掉）。
      expect(controller.state.status, startsWith('已加载塞壬唱片曲库：'));

      final Map<String, Object?> payload =
          _decode(qtSceneStateSnapshot(controller.state));
      expect(payload['index'], 0);
      expect(payload['mode'], 'archive');
      expect((payload['current'] as Map<String, Object?>?)?['cover'],
          'https://cover.test/a1.jpg');
      expect(payload['key'], isNotNull, reason: '有选中就必须带身份键，Qt 才会 prefetchCover');

      await tester.pumpWidget(const SizedBox());
      controller.dispose();
    });

    testWidgets('BasicApp 把 3D 滚动回执接到同一个 controller 窗口上', (WidgetTester tester) async {
      final _RecordingAudio audio = _RecordingAudio();
      final BasicController controller = BasicController(
        audio: audio,
        repository: _repository(<String>['s1', 's2', 's3', 's4', 's5']),
      );
      await tester.pumpWidget(BasicApp(
        controller: controller,
        audio: audio,
        bundle: _StubBundle(),
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      final ValueChanged<QtSceneScrollEvent>? wired =
          QtSceneScrollRouter.instance.handler;
      expect(wired, isNotNull, reason: 'BasicApp.initState 必须挂上回执接收面');
      final ValueChanged<QtSceneScrollEvent> handler = wired!;

      handler!(const QtSceneScrollEvent(deltaRows: 0, started: true));
      await tester.pump();
      expect(controller.state.listPosition, closeTo(0, 1e-9),
          reason: 'start 只记 origin，不动窗口');
      handler!(const QtSceneScrollEvent(deltaRows: 2.4));
      await tester.pump();
      expect(controller.state.listPosition, closeTo(2.4, 1e-9));
      expect(controller.state.selection?.id, 's1', reason: '拖动中途 3D 不落行');

      handler!(const QtSceneScrollEvent(deltaRows: 2.4, committed: true));
      await tester.pump();
      await tester.pump();
      expect(controller.state.selection?.id, 's3');
      expect(audio.calls.where((String c) => c.startsWith('play')), isEmpty,
          reason: '3D 拖动/滚轮不触发自动播放');

      await tester.pumpWidget(const SizedBox());
      expect(QtSceneScrollRouter.instance.handler, isNull, reason: 'dispose 必须摘掉回执');
      controller.dispose();
    });
  });
}
