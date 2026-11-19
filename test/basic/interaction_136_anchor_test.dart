/// INTERACTION-136 · 目录 anchor / selectedLane 一致性 + 本机集合语义回归。
///
/// 本文件**只编写、不执行**：禁令仍在（禁 dart test / flutter test / analyze / format /
/// pub get / 构建 / ADB / 设备运行），red/green 由唯一执行者 NATIVE-RECOVERY-132R 跑：
///
///   cd <worktree>
///   flutter test test/basic/interaction_136_anchor_test.dart
///
/// 真值来源（只读）：
///  - 目录折列：Qt/src/MusicDirectory.cpp:302-319 selectDirectory
///    `cell = (index + directory->anchor) % 40; selectedLane = cell / 8`；
///  - anchor 语义：Qt/src/MusicDirectory.cpp:21-31 updateSongs
///    `cell = (index + anchor) % 40; anchor = (cell - index % 40 + 40) % 40`，
///    page 恒为 `index / 40 * 40`；
///  - 打开全部歌曲：Qt/src/MusicSiren.cpp:193-246（`destination = (selectedLane+1)%5;
///    next->anchor = destination*8 + rowMemory[destination]`，**不调用 selectDirectory**，
///    首帧列号保持原 selectedLane）；
///  - ±8 换页：Qt/src/MusicDirectory.cpp:321-344 navigateDirectory（始终取模）；
///  - 退出目录：Qt/src/MusicDirectory.cpp:417-452 leaveDirectory(restore=true)
///    （恢复 parentPhysical/parentLane/parentItem，随后 selectDirectory(parent->index)）；
///  - 本机集合：Qt/src/MusicLibrary.cpp:26-30（Siren 分支直接构造 LocalCollections）、
///    Qt/src/MusicSiren.cpp:6-21 / :251-335（只读 likedIDs / playlists，无账号条件）。
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:rhine_music_database/basic/basic_hud.dart';
import 'package:rhine_music_database/basic/basic_models.dart';
import 'package:rhine_music_database/basic/siren_controller.dart';
import 'package:rhine_music_database/basic/siren_repository.dart';
import 'package:rhine_music_database/basic/platform_playback.dart';

/// 让排队的微任务/零延迟 Future 走完（沿用 test/basic/siren_controller_test.dart）。
Future<void> _settle() async {
  for (int i = 0; i < 24; i += 1) {
    await Future<void>.delayed(Duration.zero);
  }
}

SirenHttpResult _json(Object? body) =>
    SirenHttpResult(statusCode: 200, bytes: utf8.encode(jsonEncode(body)));

/// 假塞壬站点：20 首曲目（够跨页，> 8 才会出现 cell 折列差异）、2 张专辑。
class _Server {
  _Server({this.albumCount = 2, this.songCount = 20});

  final int albumCount;

  /// 曲目条数：短列表（count < 8）也要有 8 个物理行，见本文件末尾的反例。
  final int songCount;

  static final List<String> songIds = <String>[
    for (int i = 1; i <= 20; i += 1) 's${i.toString().padLeft(2, '0')}',
  ];

  Future<SirenHttpResult> handle(Uri uri) async {
    if (uri.path == '/api/songs') {
      return _json(<String, Object?>{
        'code': 0,
        'data': <Object?>[
          for (final String id in songIds.take(songCount))
            <String, Object?>{
              'cid': id,
              'name': 'Song $id',
              'albumCid': 'a1',
              'artists': <Object?>['A'],
            },
        ],
      });
    }
    if (uri.path == '/api/albums') {
      return _json(<String, Object?>{
        'code': 0,
        'data': <Object?>[
          for (int i = 1; i <= albumCount; i += 1)
            <String, Object?>{
              'cid': 'a$i',
              'name': 'Album $i',
              'artistes': <Object?>['A'],
              'coverUrl': '',
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
          'lyricUrl': '',
        },
      });
    }
    return const SirenHttpResult(statusCode: 404, bytes: <int>[]);
  }

  SirenRepository repository() =>
      SirenRepository(baseUri: Uri.parse('https://example.test'), get: handle);
}

/// 假 BasicAudioPort：记录一切调用，供“浏览不该出声”的断言用。
class _FakeAudio implements BasicAudioPort {
  final BasicAudioState _state = const BasicAudioState();
  final List<String> calls = <String>[];
  final List<void Function(BasicAudioState)> _listeners = <void Function(BasicAudioState)>[];

  @override
  BasicAudioState get state => _state;

  @override
  void addListener(void Function(BasicAudioState) listener) => _listeners.add(listener);

  @override
  void removeListener(void Function(BasicAudioState) listener) => _listeners.remove(listener);

  bool get played =>
      calls.any((String call) => call.startsWith('play:') || call.startsWith('prepare:'));

  @override
  Future<void> prepare(String url, {required int generation}) async {
    calls.add('prepare:$url:$generation');
  }

  @override
  Future<void> play({required int generation}) async => calls.add('play:$generation');

  @override
  Future<void> pause({required int generation}) async => calls.add('pause:$generation');

  @override
  Future<void> seekTo(double positionMs, {required int generation}) async =>
      calls.add('seek:${positionMs.toStringAsFixed(0)}');

  @override
  Future<void> stop() async => calls.add('stop');

  @override
  Future<void> dispose() async => calls.add('dispose');
}

/// 本机集合的假端口（Qt LocalCollections 的只读投影）。
class _FakeCollections implements BasicLocalCollections {
  _FakeCollections({this.liked = const <String>[], this.playlistRows = const <BasicLocalPlaylist>[]});

  final List<String> liked;
  final List<BasicLocalPlaylist> playlistRows;

  @override
  List<String> likedIds() => liked;

  @override
  List<BasicLocalPlaylist> playlists() => playlistRows;
}

/// 会抛错的端口：必须表现为“暂不可用”，不能被当成空库。
class _ThrowingCollections implements BasicLocalCollections {
  @override
  List<String> likedIds() => throw StateError('读取本机集合失败');

  @override
  List<BasicLocalPlaylist> playlists() => <BasicLocalPlaylist>[];
}

Future<BasicController> _loaded(
  _Server server,
  _FakeAudio audio, {
  BasicLocalCollections? collections,
}) async {
  final BasicController controller = BasicController(
    audio: audio,
    repository: server.repository(),
    collections: collections,
  );
  await controller.boot();
  await _settle();
  return controller;
}

void main() {
  group('mustFor132R：歌单行的身份与打开路径', () {
    test('「我的歌单」列的行带 kind=playlist 与行自己的 id', () {
      const BasicViewState state = BasicViewState(
        selectedLane: 2,
        localCollectionsAvailable: true,
        localPlaylists: <BasicLocalPlaylist>[
          BasicLocalPlaylist(id: 'pl-7', title: '深夜循环'),
        ],
      );
      final List<BasicListItem> items = basicLibraryItems(state);
      expect(items.length, 1);
      expect(items.single.kind, 'playlist');
      expect(items.single.id, 'pl-7');
      expect(
        BasicHudFrame.currentIdForTest(state, items.single),
        'pl-7',
        reason: '歌单行不能按 index 回落到 state.songs（那里是另一首歌的 id）',
      );
    });

    test('歌单行没有 id 时也不借用曲库', () {
      const BasicViewState state = BasicViewState(
        selectedLane: 3,
        songs: <SirenSong>[],
      );
      const BasicListItem row = BasicListItem(
        title: '我的歌单',
        kind: 'playlist',
        index: 0,
      );
      expect(BasicHudFrame.currentIdForTest(state, row), '');
    });
  });

  group('BasicDirectory.anchor（Qt selectDirectory 的 cell 折列，纯算术）', () {
    test('cell = (index + anchor) % 40；lane = cell / 8；page 恒为 index ~/ 40 * 40', () {
      final BasicDirectory directory = BasicDirectory(
        provider: sirenProvider,
        kind: 'playlist',
        id: 'siren-all',
        key: 'siren:playlist:all',
        title: '全部歌曲',
        artist: '塞壬唱片',
        cover: '',
        description: '塞壬唱片全部歌曲',
        trackCount: 60,
        virtual: true,
        songs: const <SirenSong>[],
        ids: const <String>[],
        cursor: 0,
        index: 0,
        anchor: 32, // destination 4 * 8 + rowMemory 0
      );

      expect(directory.cellAt(0), 32);
      expect(directory.laneAt(0), 4);
      expect(directory.cellAt(8), 0, reason: '(8 + 32) % 40 = 0');
      expect(directory.laneAt(8), 0);
      expect(directory.cellAt(16), 8);
      expect(directory.laneAt(16), 1);
      expect(directory.cellAt(39), 31);
      expect(directory.laneAt(39), 3);
      expect(directory.cellAt(40), 32, reason: '第二页起点的 cell 与第一页一致');
      expect(directory.laneAt(40), 4);

      expect(directory.page, 0);
      expect(directory.copyWith(index: 8).page, 0, reason: 'page 只按 40 对齐，不含 anchor');
      expect(directory.copyWith(index: 40).page, 40);
      expect(directory.copyWith(index: 47).page, 40);

      // anchor 不改 cell 之外的东西：copyWith 可独立替换 anchor。
      expect(directory.copyWith(anchor: 0).laneAt(8), 1);
      expect(directory.copyWith(anchor: 0).cellAt(8), 8);
      expect(directory.anchor, 32, reason: '原对象不可变，未被就地改写');
    });
  });

  group('打开「全部歌曲」：anchor 来自 destination/rowMemory，首帧列号不变', () {
    test('anchor = (3+1)%5*8 + rowMemory[4]；打开后 selectedLane 仍是 3（open 不 selectDirectory）',
        () async {
      final _Server server = _Server();
      final _FakeAudio audio = _FakeAudio();
      final BasicController controller = await _loaded(server, audio);
      addTearDown(controller.dispose);
      audio.calls.clear();

      expect(controller.state.selectedLane, 3);
      await controller.openAllSirenSongs();
      await _settle();

      final BasicDirectory directory = controller.state.directory!;
      expect(directory.songs.length, 20);
      expect(directory.index, 0);
      expect(directory.anchor, 32, reason: 'destination=(3+1)%5=4，rowMemory[4]=0');
      expect(directory.page, 0);
      expect(controller.state.selectedLane, 3, reason: '首帧列号=打开前的列（04 / 05）');
      expect(controller.state.song?.id, 's01', reason: '只选中第一首');
      expect(audio.played, isFalse);

      // 目录内第一行按 anchor 折在 lane 4，但 state.selectedLane 仍由 Qt 的 open 语义决定。
      expect(directory.laneAt(0), 4);
    });

    test('rowMemory 参与 anchor：在「全部专辑」选过第 2 行后，anchor = 32 + 1', () async {
      final _Server server = _Server();
      final _FakeAudio audio = _FakeAudio();
      final BasicController controller = await _loaded(server, audio);
      addTearDown(controller.dispose);
      audio.calls.clear();

      // 3 → 4（全部专辑），选中第 2 行（rowMemory[4] = 1）。
      await controller.navigateColumn(1);
      await _settle();
      expect(controller.state.selectedLane, 4);
      await controller.selectLibraryRow(1);
      await _settle();
      // 4 → 0 → 1 → 2 → 3 回到全部歌曲（sourceOrder 回环，不是单列 root no-op）。
      for (int i = 0; i < 4; i += 1) {
        await controller.navigateColumn(1);
        await _settle();
      }
      expect(controller.state.selectedLane, 3);

      await controller.openAllSirenSongs();
      await _settle();
      final BasicDirectory directory = controller.state.directory!;
      expect(directory.anchor, 33, reason: '32 + rowMemory[4]（1）');
      expect(directory.cellAt(8), 1, reason: '(8 + 33) % 40 = 1');
      expect(directory.laneAt(8), 0);
      expect(audio.played, isFalse, reason: '打开目录不播放');
    });
  });

  group('目录内 ±8：始终按 anchor 折列、始终取模，不退回单列、不是 back', () {
    test('每步 index ±8 取模，lane 由 (index+anchor)%40~/8 决定', () async {
      final _Server server = _Server();
      final _FakeAudio audio = _FakeAudio();
      final BasicController controller = await _loaded(server, audio);
      addTearDown(controller.dispose);
      audio.calls.clear();

      await controller.openAllSirenSongs();
      await _settle();
      final int anchor = controller.state.directory!.anchor;
      expect(anchor, 32);

      await controller.navigateColumn(1); // +8
      await _settle();
      expect(controller.state.directory!.index, 8);
      expect(controller.state.selectedLane, 0, reason: '(8+32)%40=0 → lane 0');
      expect(controller.state.song?.id, 's09');

      await controller.navigateColumn(1); // 16
      await _settle();
      expect(controller.state.directory!.index, 16);
      expect(controller.state.selectedLane, 1, reason: '(16+32)%40=8 → lane 1');

      await controller.navigateColumn(-1); // 8
      await _settle();
      expect(controller.state.directory!.index, 8);
      expect(controller.state.selectedLane, 0);

      await controller.navigateColumn(-1); // 0
      await _settle();
      expect(controller.state.directory!.index, 0);
      expect(controller.state.selectedLane, 4, reason: '(0+32)%40=32 → lane 4');

      // 0 再往左是绕到末尾，不是“返回上一级”。
      await controller.navigateColumn(-1);
      await _settle();
      expect(controller.state.directory, isNotNull, reason: '±8 不是 back');
      expect(controller.state.directory!.index, 12, reason: 'wrap(0-8, 20) = 12');
      expect(controller.state.selectedLane, 0, reason: '(12+32)%40=4 → lane 0');
      expect(audio.played, isFalse, reason: '目录换页只选中，不播放');
    });
  });

  group('退出目录：回到打开前的列与选中（Qt leaveDirectory(true)）', () {
    test('back() 恢复 parentLane/parentSelection 并清掉目录', () async {
      final _Server server = _Server();
      final _FakeAudio audio = _FakeAudio();
      final BasicController controller = await _loaded(server, audio);
      addTearDown(controller.dispose);
      audio.calls.clear();

      await controller.selectLibraryRow(2);
      await _settle();
      final BasicSelection? before = controller.state.selection;
      expect(before?.id, 's03');

      await controller.openAllSirenSongs();
      await _settle();
      await controller.navigateColumn(1);
      await _settle();
      expect(controller.state.selectedLane, 0);

      await controller.back();
      await _settle();
      expect(controller.state.directory, isNull);
      expect(controller.state.selectedLane, 3, reason: '回到打开目录前的列');
      expect(controller.state.selection?.id, 's03', reason: '选中身份也回到打开前');
    });

    test('打开前的父项不是曲目（专辑行）：返回后 state.song 不能留着目录里的歌', () async {
      final _Server server = _Server();
      final _FakeAudio audio = _FakeAudio();
      final BasicController controller = await _loaded(server, audio);
      addTearDown(controller.dispose);
      audio.calls.clear();

      await controller.navigateColumn(1); // 3 → 4（全部专辑）
      await _settle();
      expect(controller.state.selectedLane, 4);
      await controller.selectLibraryRow(0); // 选专辑 a1：非 song 行必须清掉 state.song
      await _settle();
      expect(controller.state.song, isNull);
      expect(controller.state.selection?.kind, 'album');

      await controller.openAllSirenSongs();
      await _settle();
      expect(controller.state.song?.id, 's01', reason: '目录首帧选中目录第一首');

      await controller.back();
      await _settle();
      expect(controller.state.directory, isNull);
      expect(controller.state.selectedLane, 4, reason: '回到打开目录前的列');
      expect(controller.state.selection?.kind, 'album', reason: '父项是专辑行');
      expect(controller.state.song, isNull,
          reason: 'Qt leaveDirectory(true) 的 current = parentItem（专辑）不是曲目');
      expect(audio.played, isFalse);
    });
  });

  group('本机集合语义（A：不是账号，没有端口就说“暂不可用”）', () {
    test('没有端口：lane 1/2 无条目、无选中，文案是“本地集合暂不可用”且不提账号', () async {
      final _Server server = _Server();
      final _FakeAudio audio = _FakeAudio();
      final BasicController controller = await _loaded(server, audio);
      addTearDown(controller.dispose);

      await controller.navigateColumn(-1); // 3 → 2（我的歌单）
      await _settle();
      expect(controller.state.selectedLane, 2);
      expect(controller.state.localCollectionsAvailable, isFalse);
      expect(controller.state.localPlaylists, isEmpty);
      expect(basicLibraryItems(controller.state), isEmpty);
      expect(controller.state.status, contains('本地集合暂不可用'));
      expect(controller.state.status, isNot(contains('账号')));

      await controller.navigateColumn(-1); // 2 → 1（喜欢的歌曲）
      await _settle();
      expect(controller.state.selectedLane, 1);
      expect(basicLibraryItems(controller.state), isEmpty);
      expect(controller.state.status, contains('本地集合暂不可用'));
      expect(controller.state.status, isNot(contains('账号')));
      expect(audio.played, isFalse);
    });

    test('注入口径：likedIDs 经曲库解析成行、playlists 成行，空才是真的空', () async {
      final _Server server = _Server();
      final _FakeAudio audio = _FakeAudio();
      final BasicController controller = await _loaded(
        server,
        audio,
        collections: _FakeCollections(
          liked: <String>['s02', 's05', 'missing-id'],
          playlistRows: const <BasicLocalPlaylist>[
            BasicLocalPlaylist(id: 'p1', title: '通勤', trackCount: 3),
          ],
        ),
      );
      addTearDown(controller.dispose);

      expect(controller.state.localCollectionsAvailable, isTrue);
      expect(controller.state.localPlaylists.map((BasicLocalPlaylist p) => p.id).toList(),
          <String>['p1']);

      await controller.navigateColumn(-1); // → 2
      await _settle();
      expect(controller.state.selectedLane, 2);
      final List<BasicListItem> playlists = basicLibraryItems(controller.state);
      expect(playlists.map((BasicListItem item) => item.kind).toList(), <String>['playlist']);
      expect(playlists.single.id, 'p1');
      expect(playlists.single.title, '通勤');
      expect(controller.state.songs, isEmpty,
          reason: '歌单列没有曲目：state.songs 不能退回整库曲目');

      await controller.navigateColumn(-1); // → 1
      await _settle();
      expect(controller.state.selectedLane, 1);
      final List<BasicListItem> liked = basicLibraryItems(controller.state);
      expect(liked.map((BasicListItem item) => item.id).toList(), <String>['s02', 's05'],
          reason: 'missing-id 解析不到就不造行');
      expect(controller.state.songs.map((SirenSong s) => s.id).toList(), <String>['s02', 's05']);
      expect(audio.played, isFalse, reason: '换列只选中，不播放');
    });

    test('端口抛错：仍然只是“暂不可用”，不能冒充空库', () async {
      final _Server server = _Server();
      final _FakeAudio audio = _FakeAudio();
      final BasicController controller = await _loaded(
        server,
        audio,
        collections: _ThrowingCollections(),
      );
      addTearDown(controller.dispose);

      expect(controller.state.localCollectionsAvailable, isFalse);
      await controller.navigateColumn(-1); // → 2
      await _settle();
      expect(controller.state.status, contains('本地集合暂不可用'));
      expect(controller.state.status, isNot(contains('暂无本地歌单')));
    });
  });

  group('根列 next 与点击选中是两条入口：滚动窗口 offsets/rowMemory 不能互相覆盖', () {
    test('lane4 十张专辑：select9 后 next+1 得 rowMemory=2，open-all anchor = 34（不是 32）', () async {
      final _Server server = _Server(albumCount: 10);
      final _FakeAudio audio = _FakeAudio();
      final BasicController controller = await _loaded(server, audio);
      addTearDown(controller.dispose);
      audio.calls.clear();

      await controller.navigateColumn(1); // 3 → 4（全部专辑）
      await _settle();
      expect(controller.state.selectedLane, 4);
      expect(controller.state.albums.length, 10);

      // 直接点击第 10 张：Qt selectResult（Qt/src/MusicLibrary.cpp:616-643）
      // offsets[4] = 9 / 8 * 8 = 8；rowMemory[4] = 9 % 8 = 1。
      await controller.selectLibraryRow(9);
      await _settle();
      expect(controller.state.selection?.id, 'a10');

      // ↓ 一次：Qt MusicLibrary::next（Qt/src/MusicLibrary.cpp:651-663）
      //   absolute = wrap(8 + 1, 10) = 9；next = wrap(9 + 1, 10) = 0
      //   target = wrap(1 + 1, 8) = 2；offsets[4] = 0 - 2 = -2；rowMemory[4] = 2
      await controller.stepLibrarySelection(1);
      await _settle();
      expect(controller.state.selection?.id, 'a1', reason: 'next 从末尾绕回第 1 张');
      expect(controller.state.selectedLane, 4);
      expect(audio.played, isFalse, reason: '逐项选中不播放');

      // 负 offsets 必须能活着穿过一次换列往返：Qt showSource 用 wrap(offsets+rowMemory,count)
      // 恢复窗口行（Qt/src/MusicLibrary.cpp:566-573），不能被“记住的选中身份/row%8”顶掉。
      await controller.navigateColumn(1); // 4 → 0（sourceOrder 回环）
      await _settle();
      expect(controller.state.selectedLane, 0);
      await controller.navigateColumn(-1); // 0 → 4
      await _settle();
      expect(controller.state.selectedLane, 4);
      expect(controller.state.selection?.id, 'a1',
          reason: 'offsets[4]=-2 → wrap(-2+2,10)=0，仍是我刚选的那张');
      expect(audio.played, isFalse);

      // 回到「全部歌曲」再打开：anchor 必须带上 next 之后的 rowMemory[4]=2。
      // 旧的 row%8 覆盖写法会把 rowMemory 归零，得 anchor=32——那是错的。
      await controller.navigateColumn(-1); // 4 → 3（sourceOrder 回环）
      await _settle();
      expect(controller.state.selectedLane, 3);

      await controller.openAllSirenSongs();
      await _settle();
      final BasicDirectory directory = controller.state.directory!;
      expect(directory.anchor, 34, reason: 'destination=4 → 32 + rowMemory[4](2)');
      expect(directory.cellAt(0), 34);
      expect(directory.laneAt(0), 4, reason: '34 ~/ 8 = 4');
      expect(audio.played, isFalse, reason: '打开目录不播放');
    });
  });

  // lead 反例：rowMemory 是 8 个**物理行**里的行号（Qt
  // `physicalSlots[lane].indexOf(selectedPhysical)` ∈ 0..7），永远不被 count 夹。
  // 旧代码 `_rowMemory[lane] >= count ? count - 1` 在 count=3 时把第 3 步的 rowMemory=3
  // 夹回 2，于是第 4 次 ↓ 又算出 0 号条目（0,1,2,0,0）。Qt/src/MusicLibrary.cpp:651-663
  // 的正确序列是 0,1,2,0,1（第 4 步 row=4、offsets=-3、wrap(-3+4,3)=1）。
  group('短列表（count<8）：物理行不按 count 夹，窗口偏移可以为负', () {
    test('count3 选 0 后连点四次 ↓：0,1,2,0,1', () async {
      final _Server server = _Server(songCount: 3);
      final _FakeAudio audio = _FakeAudio();
      final BasicController controller = await _loaded(server, audio);
      addTearDown(controller.dispose);
      audio.calls.clear();
      expect(controller.state.selectedLane, 3, reason: '首帧在「全部歌曲」列');
      expect(controller.state.songs.length, 3);

      await controller.selectLibraryRow(0);
      await _settle();
      final List<String?> visited = <String?>[controller.state.selection?.id];
      for (int i = 0; i < 4; i += 1) {
        await controller.stepLibrarySelection(1);
        await _settle();
        visited.add(controller.state.selection?.id);
      }
      expect(visited, <String>['s01', 's02', 's03', 's01', 's02'],
          reason: '物理行 0→1→2→3→4，负 offsets 仍然 wrap 到 0/1 号条目');
      expect(audio.played, isFalse, reason: '逐项选中不播放');
    });

    test('count3 选 0 后连点两次 ↑：0,2,1（负 offsets 而不是夹住）', () async {
      final _Server server = _Server(songCount: 3);
      final _FakeAudio audio = _FakeAudio();
      final BasicController controller = await _loaded(server, audio);
      addTearDown(controller.dispose);
      audio.calls.clear();

      await controller.selectLibraryRow(0);
      await _settle();
      final List<String?> visited = <String?>[controller.state.selection?.id];
      for (int i = 0; i < 2; i += 1) {
        await controller.stepLibrarySelection(-1);
        await _settle();
        visited.add(controller.state.selection?.id);
      }
      // Qt: row=0 → raw=-1 → next=wrap(-1,3)=2, target=wrap(-1,8)=7, offsets=-5；
      //     再 ↑ → row=7, absolute=wrap(-5+7,3)=2 → next=1, target=6, offsets=-5。
      expect(visited, <String>['s01', 's03', 's02']);
      expect(audio.played, isFalse);
    });

    test('count3 负偏移穿一次换列往返仍在同一条目（showSource 用 wrap(offsets+row)）', () async {
      final _Server server = _Server(songCount: 3);
      final _FakeAudio audio = _FakeAudio();
      final BasicController controller = await _loaded(server, audio);
      addTearDown(controller.dispose);
      audio.calls.clear();

      await controller.selectLibraryRow(0);
      await _settle();
      await controller.stepLibrarySelection(1);
      await _settle();
      expect(controller.state.selection?.id, 's02');

      await controller.navigateColumn(1); // 3 → 4
      await _settle();
      await controller.navigateColumn(-1); // 4 → 3
      await _settle();
      expect(controller.state.selectedLane, 3);
      expect(controller.state.selection?.id, 's02', reason: '换列不能把负偏移的窗口丢掉');
      expect(audio.played, isFalse);
    });
  });

  group('源集合非空但还解析不出：不是空收藏，也不冒充空库', () {
    test('likedIDs 全部解析不到 → “还没对上曲库”，不是“暂无喜欢的歌曲”', () async {
      final _Server server = _Server();
      final _FakeAudio audio = _FakeAudio();
      final BasicController controller = await _loaded(
        server,
        audio,
        collections: _FakeCollections(liked: <String>['missing-1', 'missing-2']),
      );
      addTearDown(controller.dispose);

      expect(controller.state.localCollectionsAvailable, isTrue,
          reason: '端口是真的查询过了');
      expect(controller.state.localUnresolvedLikedIds, 2);
      expect(controller.state.localPlaylists, isEmpty);

      await controller.navigateColumn(-1); // 3 → 2
      await _settle();
      await controller.navigateColumn(-1); // 2 → 1
      await _settle();
      expect(controller.state.selectedLane, 1);
      expect(basicLibraryItems(controller.state), isEmpty,
          reason: '解析不出的 id 不造行，也不造 SirenSong');
      expect(controller.state.status, contains('还没对上曲库'));
      expect(controller.state.status, isNot(contains('暂无喜欢的歌曲')),
          reason: '源集合非空时不能上屏 Qt 的空收藏文案');
      expect(audio.played, isFalse);
    });

    test('部分解析得到：出已解析的行，同时把未解析条数留在 state 里', () async {
      final _Server server = _Server();
      final _FakeAudio audio = _FakeAudio();
      final BasicController controller = await _loaded(
        server,
        audio,
        collections: _FakeCollections(liked: <String>['s02', 'missing-1']),
      );
      addTearDown(controller.dispose);

      expect(controller.state.localCollectionsAvailable, isTrue);
      expect(controller.state.localUnresolvedLikedIds, 1);

      await controller.navigateColumn(-1);
      await _settle();
      await controller.navigateColumn(-1);
      await _settle();
      expect(controller.state.selectedLane, 1);
      expect(controller.state.songs.map((SirenSong song) => song.id).toList(), <String>['s02'],
          reason: '已解析的照列，未解析的不造行');
      expect(controller.state.status, contains('喜欢的歌曲'));
      expect(controller.state.status, isNot(contains('暂无喜欢的歌曲')));
      expect(audio.played, isFalse);
    });

    test('端口查询成功且源集合真的空 → 才是“暂无喜欢的歌曲”', () async {
      final _Server server = _Server();
      final _FakeAudio audio = _FakeAudio();
      final BasicController controller = await _loaded(
        server,
        audio,
        collections: _FakeCollections(),
      );
      addTearDown(controller.dispose);

      expect(controller.state.localCollectionsAvailable, isTrue);
      expect(controller.state.localUnresolvedLikedIds, 0);

      await controller.navigateColumn(-1);
      await _settle();
      await controller.navigateColumn(-1);
      await _settle();
      expect(controller.state.selectedLane, 1);
      expect(controller.state.status, '暂无喜欢的歌曲');
      expect(audio.played, isFalse);
    });
  });
}
