// 双向连续滚动 + 冷启动封面闭合（FINAL-INTEGRATION-141）。
//
// Flutter → Qt：listPosition 经快照的 pos/lane/cells 投影过去，拖动中途就跟着滚；
// Qt → Flutter：archive-scroll 回执折成条目增量，落到同一个 _listPosition。
// 冷启动必须默认选中第一行，否则 Qt 收到的永远是 index=-1，prefetchCover 一次都不调。

import 'dart:async';
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
import 'package:rhine_music_database/platform/media_session.dart';
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

/// 只记录、不碰平台的媒体端口：用来钉"上报的是真实身份 + 真实读数"。
class _FakeMediaPort implements MediaSessionPort {
  final StreamController<String> _controller = StreamController<String>.broadcast();
  final List<MediaSessionState> updates = <MediaSessionState>[];
  int ensureCalls = 0;
  int disposeCalls = 0;

  @override
  Stream<String> get actions => _controller.stream;

  @override
  Future<String?> cacheDirectory() async => null;

  @override
  Future<bool> ensureStarted() async {
    ensureCalls += 1;
    return true;
  }

  @override
  Future<void> update(MediaSessionState state) async {
    updates.add(state);
  }

  @override
  Future<void> stop() async {}

  @override
  Future<void> dispose() async {
    disposeCalls += 1;
    await _controller.close();
  }

  void push(String action) => _controller.add(action);
}

void main() {
  group('快照 v4：连续窗口 + 40 格语义槽位', () {
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
      expect(payload['v'], 4);
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

  group('controller：一份窗口真值（更新即进入但窗口保小数，落行不改播放）', () {
    test('updateLibraryScroll 越过即进入：窗口保小数、选中当帧落最近行（双向）', () async {
      final _RecordingAudio audio = _RecordingAudio();
      final BasicController controller = BasicController(
        audio: audio,
        repository: _repository(<String>['s1', 's2', 's3', 's4', 's5']),
      );
      addTearDown(controller.dispose);
      await controller.boot();
      final int queueBefore = controller.state.queue.length;

      // 往下拖 2.6 行：窗口仍是 2.6（不吸附），选中当场落到最近一行 3 = s4。
      // Qt 真值：NativeScene::navigatePlane 每跨一格 select，HUD 每帧 observe(selected)。
      controller.updateLibraryScroll(2.6);
      expect(controller.state.listPosition, closeTo(2.6, 1e-9));
      expect(controller.state.selection?.id, 's4', reason: '拖动中途必须越过即进入');
      expect(controller.state.queue.length, queueBefore);
      expect(audio.calls.where((String c) => c.startsWith('play')), isEmpty);
      expect(audio.calls.where((String c) => c.startsWith('prepare')), isEmpty);
      expect(controller.state.playing, isFalse);

      final String statusMid = controller.state.status;
      expect(statusMid.startsWith('已选中'), isFalse,
          reason: '中途 observe 不播报已选中（那是抬手落定的动作）');

      // 反向拖回 1.4：同一个手势里也必须双向进入，且是"从 s4 回到 s2"这种
      // 真正会失败的方向（若只写窗口，选中会停在 s4）。
      controller.updateLibraryScroll(1.4);
      expect(controller.state.listPosition, closeTo(1.4, 1e-9));
      expect(controller.state.selection?.id, 's2', reason: '反向拖动同样越过即进入');
      controller.updateLibraryScroll(0.4);
      expect(controller.state.selection?.id, 's1');

      // 同一个位置再写一次是 no-op（防回声/防重复投影）。
      controller.updateLibraryScroll(0.4);
      expect(controller.state.listPosition, closeTo(0.4, 1e-9));
      expect(controller.state.selection?.id, 's1');
    });

    test('applyNativeArchiveScroll：start 记原点、move 越过即进入、commit 落定', () async {
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
      expect(controller.state.selection?.id, 's2', reason: '3D 手势中途越过即进入');

      controller.applyNativeArchiveScroll(2.6);
      expect(controller.state.listPosition, closeTo(2.6, 1e-9));
      expect(controller.state.selection?.id, 's4');

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

    test('手势进行中的点选回执被丢弃：拖动松手不得改写选中（双消费）', () async {
      final BasicController controller = BasicController(
        audio: _RecordingAudio(),
        repository: _repository(<String>['s1', 's2', 's3', 's4']),
      );
      addTearDown(controller.dispose);
      await controller.boot();
      final String first = controller.state.selection?.id ?? '';
      controller.applyNativeArchiveScroll(0, started: true);
      expect(controller.nativeScrollActive, isTrue);
      await controller.selectCellFromScene(3);
      expect(controller.state.selection?.id, first,
          reason: '手势进行中落行 = 双消费（用户实测"原地跳动一次"）');
      controller.applyNativeArchiveScroll(3, committed: true);
      expect(controller.nativeScrollActive, isFalse);
      await controller.selectCellFromScene(2);
      expect(controller.state.selection?.id, isNot(first));
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

  group('详情页唱片转到底 → 相邻唱片（archive-step 回执）', () {
    test('archive-step 回执解析：next/prev，其它一律 null', () {
      expect(qtSceneStepOf('archive-step:next'), 1);
      expect(qtSceneStepOf('archive-step:prev'), -1);
      expect(qtSceneStepOf('archive-step:'), isNull);
      expect(qtSceneStepOf('archive-select:3|12|song|s1'), isNull);
      expect(qtSceneStepOf('archive-scroll:move:1.5'), isNull);
    });

    test('stepDetailFromScene 换选中/详情但不播、不改队列', () async {
      final _RecordingAudio audio = _RecordingAudio();
      final BasicController controller = BasicController(
        audio: audio,
        repository: _repository(<String>['s1', 's2', 's3']),
      );
      addTearDown(controller.dispose);
      await controller.boot();
      await controller.openSong(controller.state.songs.first, play: false);
      final String from = controller.state.song!.id;
      final int queueBefore = controller.state.queue.length;
      final int prepareBefore = audio.calls.where((String c) => c.startsWith('prepare')).length;
      await controller.stepDetailFromScene(1);
      expect(controller.state.song!.id, isNot(from), reason: '转到底必须换到相邻一张');
      expect(controller.state.queue.length, queueBefore, reason: '不改队列');
      expect(audio.calls.where((String c) => c.startsWith('prepare')).length, prepareBefore,
          reason: '不自动播放');
      await controller.stepDetailFromScene(-1);
      expect(controller.state.song!.id, from, reason: '反向转回原唱片');
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
      // 曲库装载现在是多段异步（catalog → 收藏 → 平台/插件描述符），50ms 窗口不够稳；
      // 这里给到 200ms，只影响「等到位」的快慢，不改任何断言口径。
      await tester.pump(const Duration(milliseconds: 200));

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

      handler(const QtSceneScrollEvent(deltaRows: 0, started: true));
      await tester.pump();
      expect(controller.state.listPosition, closeTo(0, 1e-9),
          reason: 'start 只记 origin，不动窗口');
      handler(const QtSceneScrollEvent(deltaRows: 2.4));
      await tester.pump();
      expect(controller.state.listPosition, closeTo(2.4, 1e-9));
      expect(controller.state.selection?.id, 's3', reason: '3D 拖动中途越过即进入（行 2）');

      handler(const QtSceneScrollEvent(deltaRows: 2.4, committed: true));
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

  group('点选回执的相位守卫（审查 MUST-N4）', () {
    test('详情页收到 archive-select 一律忽略：转唱片不得静默换歌', () async {
      final _RecordingAudio audio = _RecordingAudio();
      final BasicController controller = BasicController(
        audio: audio,
        repository: _repository(<String>['s1', 's2', 's3', 's4']),
      );
      addTearDown(controller.dispose);
      await controller.boot();
      await controller.openSong(controller.state.songs.first, play: false);
      final String song = controller.state.song!.id;
      final int prepareBefore = audio.calls.where((String c) => c.startsWith('prepare')).length;

      await controller.selectCellFromScene(3);

      expect(controller.state.phase, BasicPhase.detail);
      expect(controller.state.song!.id, song, reason: '详情页相位只允许转唱片，不允许换歌');
      expect(controller.state.selection?.id, song);
      expect(audio.calls.where((String c) => c.startsWith('prepare')).length, prepareBefore,
          reason: '被守卫丢弃的回执也不能顺带准备播放');
    });

    test('归档相位仍认点选：守卫不能把正常点选一起挡掉', () async {
      final _RecordingAudio audio = _RecordingAudio();
      final BasicController controller = BasicController(
        audio: audio,
        repository: _repository(<String>['s1', 's2', 's3', 's4']),
      );
      addTearDown(controller.dispose);
      await controller.boot();
      await controller.selectCellFromScene(2);
      expect(controller.state.phase, BasicPhase.library);
      expect(controller.state.selection?.id, 's3');
      expect(audio.calls.where((String c) => c.startsWith('play')), isEmpty);
    });
  });

  group('冷启动曲库失败：真实 loading/error + 有界重试（审查 S1）', () {
    test('首次加载失败不假空，状态显示重试并自愈', () async {
      bool failedOnce = false;
      final SirenRepository repository = SirenRepository(
        get: (Uri uri) async {
          if (!failedOnce) {
            failedOnce = true;
            throw const SirenException('塞壬唱片请求失败：连接被拒绝');
          }
          switch (uri.path) {
            case '/api/songs':
              return _json(<String, Object?>{
                'code': 0,
                'data': <Object?>[
                  <String, Object?>{
                    'cid': 's1',
                    'name': 'Song s1',
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
            default:
              return _json(<String, Object?>{'code': 0, 'data': const <Object?>[]});
          }
        },
      );
      final BasicController controller = BasicController(
        audio: _RecordingAudio(),
        repository: repository,
      );
      addTearDown(controller.dispose);

      final List<String> statuses = <String>[];
      controller.addListener(() => statuses.add(controller.state.status));

      await controller.boot();
      expect(controller.state.catalogLoaded, isFalse, reason: '失败不得假装加载成功');
      expect(controller.state.error, isNotEmpty);
      expect(controller.state.status, startsWith(sirenCatalogFailurePrefix),
          reason: '失败文案保留真实原因，不追加"重试"词');
      expect(controller.state.songs, isEmpty, reason: '失败不造假数据');

      // 重试是真实 Timer（400ms 退避），等它落地；中途必须出现"正在重试第几次"。
      await Future<void>.delayed(const Duration(milliseconds: 1200));
      expect(statuses.any((String s) => s.contains('重试 1/3')), isTrue,
          reason: '重试轮次必须如实出现在 loading 文案里');
      expect(controller.state.catalogLoaded, isTrue, reason: '退避后必须自愈');
      expect(controller.state.songs, hasLength(1));
      expect(controller.state.selection, isNotNull, reason: '加载成功仍要默认选中第一行');
    });
  });

  group('系统媒体控件接的是同一个播放权威（146 接线）', () {
    test('未播放不上报身份；PLAY/PAUSE 幂等（不盲翻成相反动作）', () async {
      final _RecordingAudio audio = _RecordingAudio();
      final _FakeMediaPort port = _FakeMediaPort();
      final BasicController controller = BasicController(
        audio: audio,
        repository: _repository(<String>['s1', 's2', 's3']),
        mediaSessionPort: port,
      );
      addTearDown(controller.dispose);
      await controller.boot();

      // 没在播就不许上报任何身份：通知栏不能挂着一条空曲目。
      expect(port.updates, isEmpty);

      // 已暂停时收到系统 PLAY 之前先看 PAUSE：不得把暂停翻成播放。
      final int before = audio.calls.length;
      await controller.pause();
      await Future<void>.delayed(Duration.zero);
      expect(audio.calls.length, before,
          reason: '未在播时 PAUSE 必须幂等，不能盲翻（calls=${audio.calls}）');
    });
  });
}
