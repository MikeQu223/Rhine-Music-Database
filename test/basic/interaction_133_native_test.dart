/// INTERACTION-133 · 原生 Qt Basic HUD 四缺陷的前三项回归（选择≠播放 / ↑↓ 选曲 /
/// ←→ 列切换 / 列表真手指拖动 / 手势只在本层命中区域参与）。
///
/// 本文件**只编写、不执行**：禁令仍在（禁 dart test / flutter test / analyze / format /
/// pub get / 构建 / ADB / 设备运行），red/green 由唯一执行者 NATIVE-RECOVERY-132R 跑：
///
///   cd <worktree>
///   flutter test test/basic/interaction_133_native_test.dart
///
/// 真值来源（只读）：
///  - 选中 vs 播放：Qt/src/MusicDirectory.cpp:302-319（selectDirectory 不发 play）、
///    Qt/src/MusicPlayer.h:42（current 是播放身份，另一个对象）；
///  - ↑/↓：Qt/src/NativeHud.cpp:465/478 → NativeHudController.cpp:655-660 →
///    MusicLibrary.cpp:646-668（只动选中/滚动窗口，取模环绕，不动 player）；
///  - ←/→：NativeHudController.cpp:652-663 → MusicDirectory.cpp:321-344（±8 列）；
///  - 行点击：NativeHudMusic.cpp:79-91（selectResult/selectDirectory 都是 open=false）；
///  - 全目录：MusicSiren.cpp:193-246（只选中第一首，不 replaceQueue、不播放）。
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rhine_music_database/basic/basic_hud.dart';
import 'package:rhine_music_database/basic/basic_hud_resources.dart';
import 'package:rhine_music_database/basic/basic_models.dart';
import 'package:rhine_music_database/basic/platform_playback.dart';
import 'package:rhine_music_database/basic/siren_controller.dart';
import 'package:rhine_music_database/basic/siren_repository.dart';
import 'package:rhine_music_database/hud/protocol/hud_frame.dart';
import 'package:rhine_music_database/hud/input/hit_layer.dart';
import 'package:rhine_music_database/hud/protocol/hud_hit.dart';
import 'package:rhine_music_database/hud/text/glyph_font.dart';
import 'package:rhine_music_database/hud/text/glyph_run.dart';

/// 让排队的微任务/零延迟 Future 走完（沿用 test/basic/siren_controller_test.dart）。
Future<void> _settle() async {
  for (int i = 0; i < 16; i += 1) {
    await Future<void>.delayed(Duration.zero);
  }
}

SirenHttpResult _json(Object? body) =>
    SirenHttpResult(statusCode: 200, bytes: utf8.encode(jsonEncode(body)));

/// 假塞壬站点：只回协议形状（code:0 + data），不触网。
class _Server {
  final List<Uri> calls = <Uri>[];

  Future<SirenHttpResult> handle(Uri uri) async {
    calls.add(uri);
    if (uri.path == '/api/songs') {
      return _json(<String, Object?>{
        'code': 0,
        'data': <Object?>[
          <String, Object?>{'cid': 's1', 'name': 'Song One', 'albumCid': 'a1', 'artists': <Object?>['A']},
          <String, Object?>{'cid': 's2', 'name': 'Song Two', 'albumCid': 'a1', 'artists': <Object?>['A']},
          <String, Object?>{'cid': 's3', 'name': 'Song Three', 'albumCid': 'a2', 'artists': <Object?>['B']},
        ],
      });
    }
    if (uri.path == '/api/albums') {
      return _json(<String, Object?>{
        'code': 0,
        'data': <Object?>[
          <String, Object?>{'cid': 'a1', 'name': 'Album One', 'artistes': <Object?>['A'], 'coverUrl': ''},
          <String, Object?>{'cid': 'a2', 'name': 'Album Two', 'artistes': <Object?>['B'], 'coverUrl': ''},
        ],
      });
    }
    if (uri.path.startsWith('/api/song/')) {
      final String id = uri.path.substring('/api/song/'.length);
      return _json(<String, Object?>{
        'code': 0,
        'data': <String, Object?>{
          'name': 'Song ' + id,
          'sourceUrl': 'https://file.test/' + id + '.flac',
          'lyricUrl': '',
        },
      });
    }
    if (uri.path == '/api/album/a1/detail') {
      return _json(<String, Object?>{
        'code': 0,
        'data': <String, Object?>{
          'name': 'Album One',
          'coverUrl': '',
          'artistes': <Object?>['A'],
          'songs': <Object?>[
            <String, Object?>{'cid': 's1', 'name': 'Song One', 'artistes': <Object?>['A']},
            <String, Object?>{'cid': 's2', 'name': 'Song Two', 'artistes': <Object?>['A']},
          ],
        },
      });
    }
    return const SirenHttpResult(statusCode: 404, bytes: <int>[]);
  }

  SirenRepository repository() =>
      SirenRepository(baseUri: Uri.parse('https://example.test'), get: handle);
}

/// 假 BasicAudioPort：记录一切调用，供"浏览不该出声"的断言用。
class _FakeAudio implements BasicAudioPort {
  BasicAudioState _state = const BasicAudioState();
  final List<String> calls = <String>[];
  final List<void Function(BasicAudioState)> _listeners = <void Function(BasicAudioState)>[];

  @override
  BasicAudioState get state => _state;

  @override
  void addListener(void Function(BasicAudioState) listener) => _listeners.add(listener);

  @override
  void removeListener(void Function(BasicAudioState) listener) => _listeners.remove(listener);

  void emit(BasicAudioState next) {
    _state = next;
    for (final void Function(BasicAudioState) listener
        in List<void Function(BasicAudioState)>.of(_listeners)) {
      listener(next);
    }
  }

  bool get played => calls.any((String call) => call.startsWith('play:') || call.startsWith('prepare:'));

  @override
  Future<void> prepare(String url, {required int generation}) async {
    calls.add('prepare:' + url + ':' + generation.toString());
  }

  @override
  Future<void> play({required int generation}) async => calls.add('play:' + generation.toString());

  @override
  Future<void> pause({required int generation}) async => calls.add('pause:' + generation.toString());

  @override
  Future<void> seekTo(double positionMs, {required int generation}) async =>
      calls.add('seek:' + positionMs.toStringAsFixed(0));

  @override
  Future<void> stop() async => calls.add('stop');

  @override
  Future<void> dispose() async => calls.add('dispose');
}

BasicController _controller(_Server server, _FakeAudio audio) =>
    BasicController(audio: audio, repository: server.repository(), dark: true);

Future<BasicController> _loaded(_Server server, _FakeAudio audio) async {
  final BasicController controller = _controller(server, audio);
  await controller.boot();
  await _settle();
  return controller;
}

void main() {
  group('选择与播放严格分离（用户缺陷 1/3 的地基）', () {
    test('openSong(play: false) 只选中：song 变、playingTrack 仍空、AudioPort 一声不响', () async {
      final _Server server = _Server();
      final _FakeAudio audio = _FakeAudio();
      final BasicController controller = await _loaded(server, audio);
      addTearDown(controller.dispose);

      final SirenSong song = controller.state.songs[1];
      await controller.openSong(song, play: false);
      await _settle();

      expect(controller.state.song?.id, song.id);
      expect(controller.state.selection, isNotNull);
      expect(controller.state.selection!.id, song.id);
      expect(controller.state.playingTrack, isNull, reason: '浏览选中不等于开始播放');
      expect(audio.played, isFalse, reason: '选中路径不得调用 prepare/play');
    });

    test('真正播放时 playingTrack 才跟上，且与选中互不顶替', () async {
      final _Server server = _Server();
      final _FakeAudio audio = _FakeAudio();
      final BasicController controller = await _loaded(server, audio);
      addTearDown(controller.dispose);

      final SirenSong first = controller.state.songs.first;
      await controller.openSong(first);
      await _settle();
      expect(audio.played, isTrue);
      expect(controller.state.playingTrack?.id, first.id);

      // 选中另一首但不播放：播放身份必须留在原曲目上。
      // 首屏默认列是「全部歌曲」，列表只列曲目行，所以第 1 行就是第二首
      // （Qt/src/MusicLibrary.cpp:195-207 sourceItems(selectedLane)）。
      final SirenSong second = controller.state.songs[1];
      await controller.selectLibraryRow(1);
      await _settle();
      expect(controller.state.song?.id, second.id, reason: '选中已移动到第二首');
      expect(controller.state.song?.id, isNot(first.id), reason: '选中已移动');
      expect(controller.state.playingTrack?.id, first.id, reason: '播放身份不被浏览覆盖');
    });

    test('↑/↓ 逐项选曲：取模环绕、只动选中与滚动窗口、不碰播放器', () async {
      final _Server server = _Server();
      final _FakeAudio audio = _FakeAudio();
      final BasicController controller = await _loaded(server, audio);
      addTearDown(controller.dispose);

      final List<BasicListItem> items = basicLibraryItems(controller.state);
      expect(items.length, greaterThan(1));
      final int start = basicSelectedItemIndex(controller.state, items);
      audio.calls.clear();

      await controller.stepLibrarySelection(1);
      await _settle();
      expect(basicSelectedItemIndex(controller.state, basicLibraryItems(controller.state)),
          (start + 1) % items.length);
      expect(controller.state.listPosition, ((start + 1) % items.length).toDouble());

      await controller.stepLibrarySelection(-1);
      await _settle();
      expect(basicSelectedItemIndex(controller.state, basicLibraryItems(controller.state)), start);

      audio.calls.clear();
      // 从最后一行继续 ↓：环绕回第 0 行（Qt 的 wrap）。
      await controller.selectLibraryRow(items.length - 1);
      await controller.stepLibrarySelection(1);
      await _settle();
      expect(basicSelectedItemIndex(controller.state, basicLibraryItems(controller.state)), 0);
      expect(audio.played, isFalse, reason: '逐项选曲不得推播放队列');
    });

    test('列表拖动的落点只选中最近一行（commitLibraryScroll）', () async {
      final _Server server = _Server();
      final _FakeAudio audio = _FakeAudio();
      final BasicController controller = await _loaded(server, audio);
      addTearDown(controller.dispose);
      audio.calls.clear();

      await controller.commitLibraryScroll(1.4);
      await _settle();
      expect(controller.state.listPosition, 1.0);
      expect(controller.state.selection, isNotNull);
      expect(audio.played, isFalse);

      // 越界落点被夹在合法范围内，不产生非法下标。
      await controller.commitLibraryScroll(-5);
      await _settle();
      expect(controller.state.listPosition, 0.0);
      await controller.commitLibraryScroll(999);
      await _settle();
      final int last = basicLibraryItems(controller.state).length - 1;
      expect(controller.state.listPosition, last.toDouble());
    });
  });

  group('打开全 Siren 目录 / 目录不是播放队列', () {
    test('openAllSirenSongs 只选中第一首，不开播、不换队列', () async {
      final _Server server = _Server();
      final _FakeAudio audio = _FakeAudio();
      final BasicController controller = await _loaded(server, audio);
      addTearDown(controller.dispose);
      audio.calls.clear();

      await controller.openAllSirenSongs();
      await _settle();

      expect(controller.state.directory, isNotNull);
      expect(controller.state.directory!.index, 0);
      expect(controller.state.phase, BasicPhase.library);
      expect(controller.state.song?.id, controller.state.songs.first.id);
      expect(controller.state.queue, isEmpty, reason: '目录是列表，不是播放队列');
      expect(controller.state.queueIndex, -1);
      expect(audio.played, isFalse, reason: '打开目录不得自动播放');
    });

    test('目录内 ←/→ = ±8 列并取模，只换选中', () async {
      final _Server server = _Server();
      final _FakeAudio audio = _FakeAudio();
      final BasicController controller = await _loaded(server, audio);
      addTearDown(controller.dispose);

      await controller.openAllSirenSongs();
      await _settle();
      audio.calls.clear();

      final int count = controller.state.songs.length;
      await controller.navigateColumn(1);
      await _settle();
      expect(controller.state.directory!.index, 8 % count);
      expect(controller.state.listPosition, (8 % count).toDouble());

      await controller.navigateColumn(1);
      await _settle();
      expect(controller.state.directory!.index, (8 + 8) % count);

      expect(controller.state.directory, isNotNull, reason: '列切换不离开目录');
      expect(audio.played, isFalse);
    });

    test('目录第一行再往左 = 恒取模绕到上一页末尾（返回只走 back/music:parent）', () async {
      final _Server server = _Server();
      final _FakeAudio audio = _FakeAudio();
      final BasicController controller = await _loaded(server, audio);
      addTearDown(controller.dispose);

      await controller.openAllSirenSongs();
      await _settle();
      expect(controller.state.directory, isNotNull);

      final int count = controller.state.songs.length;
      await controller.selectLibraryRow(0);
      await controller.navigateColumn(-1);
      await _settle();

      // Qt/src/MusicDirectory.cpp:321-344 navigateDirectory(-8)：
      // `selectDirectory(((target % count) + count) % count, ...)`——第一行再往左是绕到
      // 末尾那一页，不是"返回上一级"。返回只有显式 back（Qt `music:parent`，
      // Qt/src/NativeHud.cpp:378-410 的『← 返回上一级』）。
      expect(controller.state.directory, isNotNull, reason: '← 在目录内永远是 navigateDirectory');
      final int expected = (((0 - 8) % count) + count) % count;
      expect(controller.state.directory!.index, expected);
      expect(controller.state.listPosition, expected.toDouble());
      expect(audio.played, isFalse, reason: '换页只选中，不播放');

      await controller.back();
      await _settle();
      expect(controller.state.directory, isNull, reason: '显式 back 才退出目录');
      expect(controller.state.phase, BasicPhase.library);
    });

    test('目录外 ←/→ = 按 sourceOrder() 循环换资料库列（不打开目录）', () async {
      final _Server server = _Server();
      final _FakeAudio audio = _FakeAudio();
      final BasicController controller = await _loaded(server, audio);
      addTearDown(controller.dispose);
      audio.calls.clear();

      // Qt/src/NativeHudController.cpp:658-662：无目录时
      // `showSource(sourceOrder().at(wrap(index ± 1, sources.size())))`。
      // Siren 的 sourceOrder 是 {1,2,3,4,0}（Qt/src/MusicLibrary.cpp:184-186），
      // 首屏在「全部歌曲」(3)，所以 → 依次是 4,0,1,2,3。
      expect(controller.state.selectedLane, 3);
      expect(controller.state.directory, isNull);

      final List<int> visited = <int>[3];
      for (var step = 0; step < 5; step++) {
        await controller.navigateColumn(1);
        await _settle();
        visited.add(controller.state.selectedLane);
      }
      expect(visited, <int>[3, 4, 0, 1, 2, 3], reason: '五列按 sourceOrder 回环');
      expect(controller.state.directory, isNull, reason: '换列不是打开目录');

      // 反向一步回到 sourceOrder 的上一列（3 → 2，我的歌单）。
      await controller.navigateColumn(-1);
      await _settle();
      expect(controller.state.selectedLane, 2);
      expect(controller.state.directory, isNull);

      // 账号列诚实为空：没有条目、没有选中、文案说清楚没接入，不编数据。
      expect(basicLibraryItems(controller.state), isEmpty);
      expect(controller.state.selection, isNull);
      expect(controller.state.status, contains('未接入'));

      // 我的歌单 → 全部歌曲 → 全部专辑：一路只换列。
      await controller.navigateColumn(1);
      await _settle();
      expect(controller.state.selectedLane, 3);
      expect(basicLibraryItems(controller.state), isNotEmpty);
      await controller.navigateColumn(1);
      await _settle();
      expect(controller.state.selectedLane, 4);
      expect(controller.state.selection?.kind, 'album',
          reason: '全部专辑列选中的是专辑条目');
      expect(audio.played, isFalse, reason: '换列不播放');
      expect(audio.calls, isEmpty);
    });

    test('专辑行只换身份：选中专辑后 state.song 不残留上一首（Qt choose 换 current）', () async {
      final _Server server = _Server();
      final _FakeAudio audio = _FakeAudio();
      final BasicController controller = await _loaded(server, audio);
      addTearDown(controller.dispose);
      audio.calls.clear();

      // 先在「全部歌曲」选一首真的曲目：state.song 有值。
      expect(controller.state.selectedLane, 3);
      await controller.selectLibraryRow(1);
      await _settle();
      expect(controller.state.song?.id, 's2', reason: '曲目行选中会写入 state.song');

      // 换到「全部专辑」并选专辑行：Qt MusicLibrary::choose 对非 song 会整体换
      // current，基础版把 current 拆成 selection + song，因此 song 必须清空——
      // 否则 basic_app 的 `music:play`（走 openSong(state.song)）会在专辑列播旧歌。
      await controller.navigateColumn(1);
      await _settle();
      expect(controller.state.selectedLane, 4);
      await controller.selectLibraryRow(1);
      await _settle();
      expect(controller.state.selection?.kind, 'album');
      expect(controller.state.song, isNull, reason: '专辑列不许留着上一首曲目');
      expect(audio.calls, isEmpty, reason: '选专辑行不播放');
    });
  });

  group('HUD 手势只在自己的命中区域参与（不吞 Qt 唱片区域的触摸）', () {
    BasicGlyphPorts ports() {
      final GlyphFontSet fonts = GlyphFontSet.empty;
      return BasicGlyphPorts(glyphs: fonts, text: GlyphText.resourceOnly(fonts));
    }

    BasicViewState library() {
      SirenSong song(String id, String title) => SirenSong(
            id: id,
            title: title,
            artist: '塞壬唱片',
            album: '专辑',
            albumId: 'album-1',
            cover: '',
            sourceUrl: 'https://example.invalid/' + id + '.mp3',
            lyricUrl: '',
            durationMs: 180000,
          );
      return BasicViewState(
        phase: BasicPhase.library,
        songs: <SirenSong>[song('s1', '第一首'), song('s2', '第二首')],
        albums: <SirenAlbum>[
          SirenAlbum(id: 'album-1', name: '测试专辑', artist: '塞壬唱片', cover: '', songCount: 1,
              songs: <SirenSong>[song('s1', '第一首')]),
        ],
        catalogLoaded: true,
        dark: true,
      );
    }

    Future<List<String>> pump(WidgetTester tester, {ValueChanged<double>? onScroll}) async {
      tester.view.physicalSize = const Size(1920, 1080);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final List<String> actions = <String>[];
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          backgroundColor: Colors.black,
          body: BasicHudSurface(
            state: library(),
            ports: ports(),
            onAction: actions.add,
            onLibraryScroll: onScroll,
            geometry: const StageGeometry(logicalWidth: 1920.0, logicalHeight: 1080.0),
            stage: const HudStage(scale: 1.0, width: 1920.0, height: 1080.0),
          ),
        ),
      ));
      await tester.pump();
      return actions;
    }

    testWidgets('命中矩形内的点击仍然派发真实动作', (WidgetTester tester) async {
      final List<String> actions = await pump(tester);
      final BasicHudFrame frame = BasicHudFrame.build(
        state: library(),
        ports: ports(),
        width: 1920,
        height: 1080,
        portrait: false,
      );
      final HudHit hit =
          frame.hits.firstWhere((HudHit candidate) => candidate.action == 'player:toggle');
      await tester.tapAt(Offset(hit.x + hit.width / 2, hit.y + hit.height / 2));
      await tester.pump();
      expect(actions, contains('player:toggle'));
    });

    testWidgets('命中区域外的触摸不由 HUD 消费（原样留给 Qt 场景层）', (WidgetTester tester) async {
      final List<String> actions = await pump(tester);
      final BasicHudFrame frame = BasicHudFrame.build(
        state: library(),
        ports: ports(),
        width: 1920,
        height: 1080,
        portrait: false,
      );
      // 手势层按真机 android 的 16 单位触控余量算，测试用的矩形必须同宽，
      // 否则会把"其实被 16px 余量盖住"的点当成自由区。
      final HitLayer layer = HitLayer(
        geometry: const StageGeometry(logicalWidth: 1920.0, logicalHeight: 1080.0),
        android: true,
      );
      final Rect listRect = basicLibraryListStageRect(portrait: false, width: 1920);
      bool covered(Offset point) {
        if (point.dx >= listRect.left &&
            point.dx <= listRect.right &&
            point.dy >= listRect.top &&
            point.dy <= listRect.bottom) {
          return true;
        }
        for (final HudHit hit in frame.hits) {
          final Rect rect = layer.effectiveRect(hit);
          if (point.dx >= rect.left &&
              point.dx <= rect.right &&
              point.dy >= rect.top &&
              point.dy <= rect.bottom) {
            return true;
          }
        }
        return false;
      }

      // 在场景区里找一处"HUD 没有画任何命中"的点（唱片区域的典型位置）。
      Offset? free;
      for (double y = 120; y < 900 && free == null; y += 7) {
        for (double x = 120; x < 1000; x += 7) {
          final Offset point = Offset(x, y);
          if (!covered(point)) {
            free = point;
            break;
          }
        }
      }
      expect(free, isNotNull, reason: '场景区必须存在不被 HUD 命中覆盖的可触摸区域');
      await tester.tapAt(free!);
      await tester.pump();
      expect(actions, isEmpty, reason: 'HUD 不得在全幅吞掉触摸');

      // 上面那条断言单独存在时不具备可证伪性：旧实现（整幅 GestureDetector）
      // 在 hit == null 时是静默 return，actions 同样是空的。所以再直接看命中链：
      // 自由点的手势层不得包含 HUD 的输入区域，否则 Qt 的 PlatformView 根本拿不到
      // 这次触摸（这正是"唱片区域拖不动、点不动"的机理）。
      final List<String> targets =
          tester.hitTestOnBinding(free!).path.map((e) => e.target.runtimeType.toString()).toList();
      expect(
        targets.where((t) => t.contains('_RenderHudGestureRegion')),
        isEmpty,
        reason: 'HUD 输入层不得进入区域外的命中链：$targets',
      );
    });

    testWidgets('曲目列上的竖直拖动换算成条目位移并提交落点', (WidgetTester tester) async {
      final List<double> commits = <double>[];
      await pump(tester, onScroll: commits.add);
      final Rect listRect = basicLibraryListStageRect(portrait: false, width: 1920);
      final Offset start = listRect.center;

      await tester.dragFrom(start, const Offset(0, -88));
      await tester.pumpAndSettle();

      expect(commits, isNotEmpty, reason: '拖动结束必须提交一次落点');
      // 初始 listPosition=0，向上拖一个行距 = 窗口前进一行（起点触控 slop 会被
      // 手势识别器吃掉一部分，所以只断言"明显前进且不超过两行"）。
      expect(commits.last, greaterThan(0.5));
      expect(commits.last, lessThan(1.5));
    });

    testWidgets('曲目列之外的竖直拖动不由 HUD 消费', (WidgetTester tester) async {
      final List<double> commits = <double>[];
      await pump(tester, onScroll: commits.add);
      // 场景区（左半、列表左边之外）。
      await tester.dragFrom(const Offset(600, 600), const Offset(0, -200));
      await tester.pumpAndSettle();
      expect(commits, isEmpty);
    });
  });
}
