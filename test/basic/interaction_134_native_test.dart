/// INTERACTION-134 · 资料库**五列**导航的回归（原 Qt 语义，替换 133 的两处偏离）。
///
/// 133 的审查 PASS 漏掉的根因：把 Siren 的「资料库五列」压成了一列，于是
///  - 目录第一行再往左 → 退目录（Qt 是**取模环绕**到上一页末尾）；
///  - 目录外向右 → 打开『全部歌曲』目录（Qt 是 `showSource(sourceOrder ±1)` 换列）；
///  - 根页列表 = 专辑行 + 曲目行混排（Qt 只列 `sourceItems(selectedLane)` 这一列）。
///
/// 真值（只读）：
///  - 五列与顺序：Qt/src/MusicLibrary.cpp:26-27 `columns`、:184-186 `sourceOrder()` = {1,2,3,4,0}；
///  - 根页只列当前列：Qt/src/MusicLibrary.cpp:195-207 `sourceItems(lane)` / :211-213 `libraryItems()`；
///  - ←/→ 分派：Qt/src/NativeHudController.cpp:650-662（目录内 ±8、目录外 showSource）；
///  - 目录内恒取模：Qt/src/MusicDirectory.cpp:321-344 `((target % count) + count) % count`；
///  - 行点击 = 只选中：Qt/src/NativeHudMusic.cpp:79-91（selectResult(..., false)）；
///  - ↑/↓ = 资料库逐项选曲（`music.next(±1)`），不是播放器 previous/next；
///  - archive 页两个 Siren 控制只在 `!directory && isSiren && selectedLane == 3` 出现：
///    Qt/src/NativeHud.cpp:391-430。
///
/// 本文件**只编写、不执行**：禁令仍在（禁 dart test / flutter test / analyze / format /
/// pub get / 构建 / ADB / 设备运行），red/green 由唯一执行者 NATIVE-RECOVERY-132R 跑：
///
///   cd .agents/parity-20261109/worktrees/INTERACTION-134
///   flutter test test/basic/interaction_134_native_test.dart
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rhine_music_database/basic/basic_app.dart';
import 'package:rhine_music_database/basic/basic_hud.dart';
import 'package:rhine_music_database/basic/basic_hud_resources.dart';
import 'package:rhine_music_database/basic/basic_models.dart';
import 'package:rhine_music_database/basic/platform_playback.dart';
import 'package:rhine_music_database/basic/siren_controller.dart';
import 'package:rhine_music_database/hud/input/hit_layer.dart';
import 'package:rhine_music_database/hud/protocol/hud_hit.dart';
import 'package:rhine_music_database/hud/text/glyph_font.dart';
import 'package:rhine_music_database/hud/text/glyph_run.dart';

SirenSong _song(String id, String title) => SirenSong(
      id: id,
      title: title,
      artist: '塞壬唱片',
      album: '专辑',
      albumId: 'album-1',
      cover: '',
      sourceUrl: 'https://example.invalid/$id.mp3',
      lyricUrl: '',
      durationMs: 180000.0,
    );

SirenAlbum _album(String id, String name) => SirenAlbum(
      id: id,
      name: name,
      artist: '塞壬唱片',
      cover: '',
      songCount: 1,
      songs: <SirenSong>[_song('s1', '第一首')],
    );

/// 播放端口替身：不订阅平台通道，只做空操作（同 runtime_startup_test.dart 的理由）。
class _FakeAudio implements BasicAudioPort {
  final List<void Function(BasicAudioState)> _listeners =
      <void Function(BasicAudioState)>[];

  int disposes = 0;
  final BasicAudioState _state = BasicAudioState.idle;

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

  @override
  Future<void> prepare(String url, {required int generation}) async {}

  @override
  Future<void> play({required int generation}) async {}

  @override
  Future<void> pause({required int generation}) async {}

  @override
  Future<void> seekTo(double positionMs, {required int generation}) async {}

  @override
  Future<void> stop() async {}

  @override
  Future<void> dispose() async {
    disposes += 1;
    for (final void Function(BasicAudioState) listener in _listeners) {
      listener(BasicAudioState.idle);
    }
  }
}

class _StubGlyphBundle extends AssetBundle {
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

/// 外壳分派替身：不 boot（不起 ticker、不读网络），只记「哪条动作落到哪个 controller API」。
/// 每个 override 都记独立列表，断言才能分辨「换列」与「打开」、「选曲」与「播放器跳曲」。
class _RouteController extends BasicController {
  _RouteController({required _FakeAudio audio}) : super(audio: audio);

  final List<int> selectedRows = <int>[];
  final List<int> columnDirections = <int>[];
  final List<int> stepDirections = <int>[];
  final List<String> openedSongs = <String>[];
  final List<String> openedAlbums = <String>[];
  int allSirenOpens = 0;
  int backCalls = 0;
  int playerNextCalls = 0;
  int playerPreviousCalls = 0;
  int toggleCalls = 0;

  BasicViewState? stateOverride;

  @override
  BasicViewState get state => stateOverride ?? super.state;

  void publish(BasicViewState value) {
    stateOverride = value;
    notifyListeners();
  }

  @override
  Future<void> boot() async {}

  @override
  Future<void> selectLibraryRow(int row) async {
    selectedRows.add(row);
  }

  @override
  Future<void> stepLibrarySelection(int direction) async {
    stepDirections.add(direction);
  }

  @override
  Future<void> navigateColumn(int direction) async {
    columnDirections.add(direction);
  }

  @override
  Future<void> openSong(SirenSong song, {bool play = true}) async {
    openedSongs.add(song.id);
  }

  @override
  Future<void> openAlbum(SirenAlbum album) async {
    openedAlbums.add(album.id);
  }

  @override
  Future<void> openAllSirenSongs() async {
    allSirenOpens += 1;
  }

  @override
  Future<void> back() async {
    backCalls += 1;
  }

  @override
  Future<void> next() async {
    playerNextCalls += 1;
  }

  @override
  Future<void> previous() async {
    playerPreviousCalls += 1;
  }

  @override
  Future<void> togglePlay() async {
    toggleCalls += 1;
  }
}

BasicGlyphPorts _ports() {
  final GlyphFontSet fonts = GlyphFontSet.empty;
  return BasicGlyphPorts(glyphs: fonts, text: GlyphText.resourceOnly(fonts));
}

/// 与 runtime_startup_test.dart 同一手法：直接走外壳交给 HUD 的公开回调
/// [BasicHudSurface.onAction]，等价于点中某个热区，但不需要像素坐标。
void _fire(WidgetTester tester, String action) {
  tester.widget<BasicHudSurface>(find.byType(BasicHudSurface)).onAction(action);
}

Future<_RouteController> _pumpShell(WidgetTester tester, BasicViewState state) async {
  final _FakeAudio audio = _FakeAudio();
  final _RouteController controller = _RouteController(audio: audio);
  controller.stateOverride = state;
  await tester.binding.setSurfaceSize(const Size(1920, 1080));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(BasicApp(
    controller: controller,
    audio: audio,
    bundle: _StubGlyphBundle(),
  ));
  await tester.pump();
  await tester.pump();
  expect(find.byType(BasicHudSurface), findsOneWidget);
  return controller;
}

/// 全部歌曲列（lane 3）+ 一张专辑：用来分辨「列里的曲目行」与「专辑行」。
BasicViewState _libraryState({int lane = basicDefaultLane}) => BasicViewState(
      phase: BasicPhase.library,
      selectedLane: lane,
      albums: <SirenAlbum>[_album('album-1', '专辑一')],
      songs: <SirenSong>[_song('s1', '第一首'), _song('s2', '第二首')],
      catalogLoaded: true,
    );

/// 目录打开后的投影（Qt `directory != null`）：列表只有目录曲目、相位仍是 library。
BasicViewState _directoryState({int lane = basicDefaultLane}) {
  final List<SirenSong> songs = <SirenSong>[
    _song('s1', '第一首'),
    _song('s2', '第二首'),
    _song('s3', '第三首'),
  ];
  return BasicViewState(
    phase: BasicPhase.library,
    selectedLane: lane,
    songs: songs,
    directory: BasicDirectory(
      provider: sirenProvider,
      kind: 'playlist',
      id: sirenAllSongsId,
      key: sirenAllSongsKey,
      title: sirenAllSongsTitle,
      artist: sirenProviderLabel,
      cover: '',
      description: sirenAllSongsDescription,
      trackCount: songs.length,
      virtual: true,
      songs: songs,
      ids: <String>[for (final SirenSong song in songs) song.id],
      cursor: songs.length,
      index: 0,
      parentLane: basicDefaultLane,
      parentSelection: const BasicSelection(kind: 'song', id: 's1'),
    ),
    song: songs.first,
    selection: const BasicSelection(kind: 'song', id: 's1'),
    catalogLoaded: true,
  );
}

void main() {
  group('外壳按原 Qt 语义分派（真实 BasicHudSurface.onAction → BasicApp）', () {
    testWidgets('column-prev/next → navigateColumn(±1)：换列，不打开专辑/歌曲',
        (WidgetTester tester) async {
      final _RouteController controller = await _pumpShell(tester, _libraryState());

      _fire(tester, 'column-next');
      await tester.pump();
      _fire(tester, 'column-prev');
      await tester.pump();

      // Qt/src/NativeHudController.cpp:650-662 只有 navigateColumn / showSource 两条分支，
      // 133 曾把 column-next 接到 openAllSirenSongs()、把 column-prev 接到 back()。
      expect(controller.columnDirections, <int>[1, -1]);
      expect(controller.openedAlbums, isEmpty, reason: '换列不是翻专辑');
      expect(controller.openedSongs, isEmpty, reason: '换列不播放');
      expect(controller.allSirenOpens, 0, reason: '目录外向右不是打开全部歌曲');
      expect(controller.backCalls, 0, reason: '目录外向左不是返回');
      expect(controller.toggleCalls, 0);

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('prev/next（↑/↓）→ stepLibrarySelection(±1)：不碰播放器 next/previous',
        (WidgetTester tester) async {
      final _RouteController controller = await _pumpShell(tester, _libraryState());

      _fire(tester, 'prev');
      await tester.pump();
      _fire(tester, 'next');
      await tester.pump();

      // Qt/src/NativeHudController.cpp:654-657 `prev`/`next` → `music.next(±1)`
      // 是资料库逐项选曲；播放器换曲是两个完全不同的动作（player:prev/player:next）。
      expect(controller.stepDirections, <int>[-1, 1]);
      expect(controller.playerNextCalls, 0, reason: '↑/↓ 不是播放器 next');
      expect(controller.playerPreviousCalls, 0, reason: '↑/↓ 不是播放器 previous');
      expect(controller.openedSongs, isEmpty);

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('播放器自己的 prev/next 仍然只到 previous()/next()',
        (WidgetTester tester) async {
      final _RouteController controller = await _pumpShell(tester, _libraryState());

      _fire(tester, 'player:prev');
      await tester.pump();
      _fire(tester, 'player:next');
      await tester.pump();

      expect(controller.playerPreviousCalls, 1);
      expect(controller.playerNextCalls, 1);
      expect(controller.stepDirections, isEmpty, reason: '播放器换曲不动资料库选中');

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('music:index / music:slot 只选中：不打开、不播放',
        (WidgetTester tester) async {
      final _RouteController controller = await _pumpShell(tester, _libraryState());

      _fire(tester, 'music:index:1');
      await tester.pump();
      _fire(tester, 'music:slot:0');
      await tester.pump();

      // Qt/src/NativeHudMusic.cpp:47-66 与 :79-91 都是 open=false 的纯选中。
      expect(controller.selectedRows, <int>[1, 0]);
      expect(controller.openedSongs, isEmpty, reason: '点行不播放');
      expect(controller.openedAlbums, isEmpty, reason: '点行不打开');
      expect(controller.toggleCalls, 0);

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('music:open-all-siren 仍然走真实目录入口', (WidgetTester tester) async {
      final _RouteController controller = await _pumpShell(tester, _libraryState());

      _fire(tester, 'music:open-all-siren');
      await tester.pump();

      expect(controller.allSirenOpens, 1);
      expect(controller.openedAlbums, isEmpty, reason: '打开目录不打开专辑');
      expect(controller.openedSongs, isEmpty, reason: '打开目录不播放');

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('music:play-loaded 打开**当前列**第一条：歌曲列=曲目，专辑列=专辑',
        (WidgetTester tester) async {
      final _RouteController songs = await _pumpShell(tester, _libraryState(lane: 3));

      _fire(tester, 'music:play-loaded');
      await tester.pump();
      expect(songs.openedSongs, <String>['s1'], reason: '全部歌曲列第一条是曲目');
      expect(songs.openedAlbums, isEmpty);

      await tester.pumpWidget(const SizedBox());

      final _RouteController albums = await _pumpShell(tester, _libraryState(lane: 4));
      _fire(tester, 'music:play-loaded');
      await tester.pump();
      expect(albums.openedAlbums, <String>['album-1'], reason: '全部专辑列第一条是专辑');
      expect(albums.openedSongs, isEmpty);

      await tester.pumpWidget(const SizedBox());
    });
  });

  // ---------------------------------------------------------------------------
  // HUD 字节：列号 / sourceOrder / 目录状态真的进了绘制与命中，而不是写死的 3/5/2
  // ---------------------------------------------------------------------------
  //
  // 断言的是**可证伪的产物**：`BasicHudFrame.build` 返回的 hits（要派发的动作）
  // 与 commands 里的 ['text', value, ...]（真的写进画面的字）。
  // 真值出处：Qt/src/NativeHud.cpp:391-430（两个 Siren 控制的门控）、
  // :471-499（8 slot + 四箭头）、:482-490（COLLECTION xx / 05 与 TRACK COLUMN xx / 05）。
  group('HUD 的真实字节跟着真实列号（BasicHudFrame.build）', () {
    // 用 testWidgets 而不是 test：build() 里要量字宽（text.glyphWidth），
    // 量宽走 TextPainter，需要已初始化的测试 binding。
    BasicHudFrame frameOf(BasicViewState state, {required bool portrait}) {
      return BasicHudFrame.build(
        state: state,
        ports: _ports(),
        width: portrait ? 1080 : 1920,
        height: portrait ? 1920 : 1080,
        portrait: portrait,
      );
    }

    Set<String> actionsOf(BasicViewState state, {bool portrait = false}) =>
        <String>{for (final HudHit hit in frameOf(state, portrait: portrait).hits) hit.action};

    /// 画面里出现过的字（`['text', value, ...]` 的 value）。
    Set<String> textsOf(BasicViewState state, {bool portrait = false}) {
      final Set<String> values = <String>{};
      for (final List<Object?> command in frameOf(state, portrait: portrait).commands) {
        if (command.length > 1 && command.first == 'text' && command[1] is String) {
          values.add(command[1]! as String);
        }
      }
      return values;
    }

    testWidgets('全部歌曲列（lane 3）：8 个 slot + 四箭头 + 两个 Siren 控制', (WidgetTester tester) async {
      final Set<String> actions = actionsOf(_libraryState(lane: 3));

      for (var index = 0; index < 8; index++) {
        expect(actions, contains('music:slot:$index'),
            reason: '一列 8 行的命中（Qt/src/NativeHud.cpp:471-475）');
      }
      expect(actions, contains('prev'));
      expect(actions, contains('next'));
      expect(actions, contains('column-prev'));
      expect(actions, contains('column-next'));
      // Qt/src/NativeHud.cpp:420-427：`!directory && isSiren && selectedLane == 3`。
      expect(actions, contains('music:play-loaded'));
      expect(actions, contains('music:open-all-siren'));
      // 列号也是真值：sourceOrder {1,2,3,4,0} 里 lane 3 排第 3（index 2 → '03'）。
      expect(textsOf(_libraryState(lane: 3)), contains('COLLECTION 03 / 05'),
          reason: 'Qt NativeHud.cpp:482-484 用 sourceOrder().indexOf(selectedLane)+1');
    });

    testWidgets('全部专辑列（lane 4）：条目是专辑、箭头在，但两个 Siren 控制消失',
        (WidgetTester tester) async {
      final BasicViewState state = _libraryState(lane: 4);
      final Set<String> actions = actionsOf(state);

      expect(actions, contains('column-prev'));
      expect(actions, contains('column-next'));
      expect(actions.contains('music:open-all-siren'), isFalse,
          reason: '『在资料库中打开』只属于 lane 3');
      expect(actions.contains('music:play-loaded'), isFalse,
          reason: '『播放全部』只属于 lane 1（喜欢）与 siren 的 lane 3');
      // lane 4 在 sourceOrder 里排第 4（index 3 → '04'），不是永远画 '03'。
      expect(textsOf(state), contains('COLLECTION 04 / 05'));
      // 专辑列的行是 album：Qt `showTrackList = trackListMode && kind == "song"` 为假，
      // 于是走标题/打开按钮分支，出现 open 命中（不是曲目列表）。
      expect(actions, contains('open'));
    });

    testWidgets('空列（lane 0/1/2）：没有槽位与两个 Siren 控制，四箭头与重试仍在',
        (WidgetTester tester) async {
      for (final int lane in <int>[basicSearchLane, 1, 2]) {
        final Set<String> actions = actionsOf(_libraryState(lane: lane));
        // Qt/src/NativeHud.cpp:464-499：`prev`/`next`/`column-prev`/`column-next`
        // 四个箭头画在 empty()/archive() 两个分支**之外**，空列照样有箭头；
        // 受 Qt :405-408 `if (!item.isEmpty() && !id.isEmpty())` 门控的是
        // 8 个 slot、两个 Siren 控制与目录控制。
        expect(actions, contains('column-prev'), reason: 'lane $lane 仍有 ← 箭头');
        expect(actions, contains('column-next'), reason: 'lane $lane 仍有 → 箭头');
        expect(actions, contains('prev'), reason: 'lane $lane 仍有 ↑ 箭头');
        expect(actions, contains('next'), reason: 'lane $lane 仍有 ↓ 箭头');
        expect(actions.contains('music:slot:0'), isFalse, reason: 'lane $lane 没有槽位');
        expect(actions.contains('music:play-loaded'), isFalse);
        expect(actions.contains('music:open-all-siren'), isFalse);
        // 空列给的是诚实空态 + 重试控制（basic_hud.dart 的 items.isEmpty 分支）。
        expect(actions, contains('retry'), reason: 'lane $lane 的空态要能重试');
      }
    });

    testWidgets('目录内：『← 返回上一级』music:parent + 目录的播放全部，列号保持打开前的列',
        (WidgetTester tester) async {
      final BasicViewState state = _directoryState();
      final Set<String> actions = actionsOf(state);

      // Qt/src/NativeHud.cpp:410：`control("← 返回上一级", 59, 211, 280, "music:parent")`。
      expect(actions, contains('music:parent'));
      expect(actions, contains('music:directory-info'), reason: '歌单详情入口（:412-418）');
      // :420-423：`directory && kind ∈ {playlist, album, folder}` → 播放全部。
      expect(actions, contains('music:play-loaded'));
      // :425-426 的『在资料库中打开』只属于资料库根，目录里不该有。
      expect(actions.contains('music:open-all-siren'), isFalse);
      // 目录里的列号换成语义不同的 'TRACK COLUMN xx / 05'（Qt :487-488）。
      // Qt/src/MusicSiren.cpp:236-243 的 openSirenAllSongs 不调 selectDirectory，
      // selectedLane 保持 3，所以首帧是 04 / 05 而不是 01 / 05。
      expect(textsOf(state), contains('TRACK COLUMN 04 / 05'));
      expect(textsOf(state).contains('COLLECTION 04 / 05'), isFalse);
      // 目录里仍然是一列 8 行。
      for (var index = 0; index < 8; index++) {
        expect(actions, contains('music:slot:$index'));
      }
    });

    testWidgets('竖屏也画列表与列号（不是只有横屏才画 8 个槽位）', (WidgetTester tester) async {
      final Set<String> actions = actionsOf(_libraryState(lane: 3), portrait: true);
      for (var index = 0; index < 8; index++) {
        expect(actions, contains('music:slot:$index'));
      }
      expect(actions, contains('column-next'));
      expect(textsOf(_libraryState(lane: 3), portrait: true), contains('COLLECTION 03 / 05'));
    });
  });

  group('HUD ownership：只有 HUD 自己画的区域归 HUD，其余让给 Qt 场景', () {
    // 原生 raw pointer 适配层必须用**同一张**命中地图在 down 时决定 ownership：
    // 命中 HUD＝这条指针整条序列归 Flutter（不转发 Qt），命中场景＝转发 Qt 并
    // 捕获到终止事件。现行 native WIP 无条件转发每个 hit
    // （reports/LEAD-RAW-POINTER-20261116.md:617-638），一旦 sceneRect 变全幅，
    // HUD 的按钮/列表/ruler/模态会同时打到 Qt（双消费）。
    const double width = 1920;
    const double height = 1080;
    const StageGeometry landscape =
        StageGeometry(logicalWidth: width, logicalHeight: height);

    // 竖屏真机 stage 是 logical/scale：basic_app 传 `stage.width`（1080/1.5 = 720），
    // 不是 1080 逻辑宽——用错宽度会让整张 ownership 图与生产图不同（假绿/假红）。
    const double portraitScale = 1.5;
    const double portraitWidth = 1080 / portraitScale;
    const double portraitHeight = 1920 / portraitScale;

    List<Rect> ownedOf(BasicViewState state, {bool portrait = false}) =>
        basicHudOwnedStageRects(
          state: state,
          ports: _ports(),
          geometry: portrait
              ? StageGeometry.withScale(
                  stageScale: portraitScale, logicalWidth: 1080, logicalHeight: 1920)
              : landscape,
          width: portrait ? portraitWidth : width,
          height: portrait ? portraitHeight : height,
          portrait: portrait,
        );

    testWidgets('每个 HUD 命中中心都归 HUD：按钮/slot/ruler 不会被让给 Qt',
        (WidgetTester tester) async {
      final BasicViewState state = _libraryState(lane: 3);
      final List<Rect> owned = ownedOf(state);
      final BasicHudFrame frame = BasicHudFrame.build(
        state: state,
        ports: _ports(),
        width: width,
        height: height,
        portrait: false,
      );
      expect(frame.hits, isNotEmpty);
      for (final HudHit hit in frame.hits) {
        final Offset center = Offset(hit.x + hit.width / 2, hit.y + hit.height / 2);
        expect(basicHudOwnsStagePoint(center, regions: owned), isTrue,
            reason: 'HUD 命中 ${hit.action} 必须归 HUD，否则点击会漏到 Qt 场景');
      }
      // 曲目列（拖动/点选）整块归 HUD，哪怕落在空白行上。
      final Rect list = basicLibraryListStageRect(portrait: false, width: width);
      expect(basicHudOwnsStagePoint(list.center, regions: owned), isTrue,
          reason: '曲目列拖动必须归 HUD（Qt 的 ruler 只吃选曲，不吃拖动）');
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('场景区不归 HUD：全幅 sceneRect 不等于全幅 HUD', (WidgetTester tester) async {
      final List<Rect> owned = ownedOf(_libraryState(lane: 3));
      // 横屏 sceneRect = (0,0,1920,984)（basicSceneStageRect）。
      // 唱片区中心 (960,300) 在两侧命中之外：左栏 control 止于 x=59+310=369
      // （NativeHud.cpp:410-426），右栏从 col=width*0.5234375≈1005 起
      // （lib/hud/pages/archive_page.dart:479-490），ruler 命中在 y≥509。
      const Offset scenePoint = Offset(960, 300);
      final Rect? scene = basicSceneStageRect(portrait: false, width: width, height: height);
      expect(scene, isNotNull);
      expect(scene!.contains(scenePoint), isTrue, reason: '这个点必须真的在场景里');
      expect(basicHudOwnsStagePoint(scenePoint, regions: owned), isFalse,
          reason: '场景区必须让给 Qt，否则唱片拖动/左右旋转会被 HUD 手势层吞掉');
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('竖屏：列表在 1080 之后，ownership 跟着真机 720 宽的 stage 坐标',
        (WidgetTester tester) async {
      final List<Rect> owned = ownedOf(_libraryState(lane: 3), portrait: true);
      final Rect list = basicLibraryListStageRect(portrait: true, width: portraitWidth);
      expect(list.top, basicPortraitListOffset);
      expect(basicHudOwnsStagePoint(list.center, regions: owned), isTrue);
      // 竖屏场景是 0..1080 设计高度（basicSceneStageRect），列表带在它下面。
      // 取 (200,600)：在场景矩形内、在列表带(1080..1690)之上、在左栏控制
      // (y≤335)、底部箭头带(y≥884)、ruler(y≥509, x≥1131)之外。
      const Offset scenePoint = Offset(200, 600);
      final Rect? scene = basicSceneStageRect(
          portrait: true, width: portraitWidth, height: portraitHeight);
      expect(scene, isNotNull);
      expect(scene!.contains(scenePoint), isTrue, reason: '这个点必须真的在竖屏场景里');
      expect(basicHudOwnsStagePoint(scenePoint, regions: owned), isFalse,
          reason: '竖屏场景同样归 Qt，不能被 HUD ownership 吞掉');
      await tester.pumpWidget(const SizedBox());
    });
  });
}
