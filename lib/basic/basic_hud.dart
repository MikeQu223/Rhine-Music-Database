import 'package:flutter/foundation.dart' show TargetPlatform, defaultTargetPlatform;
import 'package:flutter/material.dart';

import '../hud/input/hit_layer.dart';
import '../hud/modals/lyrics_panel.dart' as lyrics;
import '../hud/pages/archive_page.dart';
import '../hud/pages/chrome.dart';
import '../hud/pages/song_detail.dart' as detail;
import '../hud/player/player_bar.dart' as player;
import '../hud/protocol/hud_frame.dart';
import '../hud/protocol/hud_hit.dart';
import '../hud/render/hud_painter.dart';
import '../hud/widgets/track_ruler.dart' as ruler;
import '../ui/layout/portrait_stage.dart';
import 'basic_hud_resources.dart';
import 'basic_models.dart';
import 'qt_scene_view.dart';

/// 资料库名（Qt NativeHud.cpp:380 的 "MUSIC DATABASE / <libraryName>"）。
const String basicLibraryName = '塞壬唱片';

/// 竖屏重排时，曲目列从 1080 设计高度之后开始（stage unit）。
const double basicPortraitListOffset = 1080.0;

/// 侧栏起点：Qt NativeHud.cpp:408 `navigationLeft(width) = width - 789`。
double basicNavigationLeft(double width) => width - 789;

/// 一条可点条目：资料库首屏同时承载专辑与曲目，专辑页只承载该专辑曲目。
/// kind/index 指回 [BasicViewState] 的列表，绘制与命中共用。
class BasicListItem {
  const BasicListItem({required this.title, required this.kind, required this.index});

  final String title;
  final String kind;
  final int index;
}

/// 绘制与命中共用的一份列表真值。
List<BasicListItem> basicLibraryItems(BasicViewState state) {
  if (state.directory != null) {
    // Qt/src/MusicLibrary.cpp:212-214 `directory ? directory->orderedSongs() : …`：
    // 目录打开时列表只有目录曲目（不再有专辑行），行号就是目录位置。
    return <BasicListItem>[
      for (var index = 0; index < state.songs.length; index++)
        BasicListItem(
          title: state.songs[index].title.isEmpty ? sirenUnknownTitle : state.songs[index].title,
          kind: 'song',
          index: index,
        ),
    ];
  }
  final SirenAlbum? album = state.album;
  if (state.phase == BasicPhase.detail && album != null) {
    return <BasicListItem>[
      for (var index = 0; index < album.songs.length; index++)
        BasicListItem(
          title: album.songs[index].title.isEmpty ? sirenUnknownTitle : album.songs[index].title,
          kind: 'song',
          index: index,
        ),
    ];
  }
  return <BasicListItem>[
    for (var index = 0; index < state.albums.length; index++)
      BasicListItem(
        title: state.albums[index].name.isEmpty ? '未命名专辑' : state.albums[index].name,
        kind: 'album',
        index: index,
      ),
    for (var index = 0; index < state.songs.length; index++)
      BasicListItem(
        title: state.songs[index].title.isEmpty ? sirenUnknownTitle : state.songs[index].title,
        kind: 'song',
        index: index,
      ),
  ];
}

/// 当前高亮条目（Qt MusicLibrary::libraryIndex()，Qt/src/MusicLibrary.cpp:196-212）。
///
/// 目录内用 directory.index —— Qt MusicDirectory::index 是位置真值，selectDirectory
/// 先写它再 choose（Qt/src/MusicDirectory.cpp:302-319）。
///
/// 资料库/专辑页按**身份**在 items 里找自己的行：先用当前曲目 id 匹配 kind == 'song'
/// 行的源曲目，再用当前专辑 id 匹配 kind == 'album' 行的源专辑。items 同时含专辑与曲目时
/// 行序与 state.songs 的下标并不相同（专辑行占前段），所以不能拿 state.songs 的下标当行号，
/// 也没有固定偏移可加；标题可能重复，不能按标题匹配。
int basicSelectedItemIndex(BasicViewState state, List<BasicListItem> items) {
  if (items.isEmpty) {
    return 0;
  }
  final BasicDirectory? directory = state.directory;
  if (directory != null) {
    final int index = directory.index;
    return index < 0 || index >= items.length ? 0 : index;
  }
  final String songId = state.song?.id ?? '';
  if (songId.isNotEmpty) {
    for (var position = 0; position < items.length; position++) {
      final BasicListItem item = items[position];
      if (item.kind != 'song' || item.index < 0 || item.index >= state.songs.length) {
        continue;
      }
      if (state.songs[item.index].id == songId) {
        return position;
      }
    }
  }
  final String albumId = state.album?.id ?? '';
  if (albumId.isNotEmpty) {
    for (var position = 0; position < items.length; position++) {
      final BasicListItem item = items[position];
      if (item.kind != 'album' || item.index < 0 || item.index >= state.albums.length) {
        continue;
      }
      if (state.albums[item.index].id == albumId) {
        return position;
      }
    }
  }
  return 0;
}

/// 资料库标题（Qt MusicLibrary::libraryName()，Qt/src/MusicLibrary.cpp:189-194）：
/// 目录打开时是目录标题（'全部歌曲'），否则是 provider 名。
String basicLibraryTitle(BasicViewState state) {
  final String title = state.directory?.title ?? '';
  return title.isEmpty ? basicLibraryName : title;
}

/// 一帧的扁平命令流 + 命中集合。绘制（HudStagePainter）与命中（HitLayer）
/// 消费同一份，禁止各自再推导坐标。
class BasicHudFrame {
  BasicHudFrame({required this.generation, required this.commands, required this.hits});

  final int generation;
  final List<List<Object?>> commands;
  final List<HudHit> hits;

  static int _generation = 0;

  static BasicHudFrame build({
    required BasicViewState state,
    required BasicGlyphPorts ports,
    required double width,
    required double height,
    required bool portrait,
  }) {
    final _HudSink sink = _HudSink();
    final bool dark = state.dark;
    HudChrome(sink, ports, dark: dark).chromeView(
      width: width,
      archiveMode: state.phase == BasicPhase.library && !portrait,
      // 场景铺满整窗（见 basicSceneStageRect），3D 会画到右栏文字下面，所以归档态必须
      // 让 HudChrome 自己盖右栏遮罩（lib/hud/pages/chrome.dart:231 的 archiveMask，
      // fadeWidth 300 = 原 Qt 的 NativeHud.cpp:313-330 FadeWidth）。
      suppressMask: false,
      libraryName: basicLibraryTitle(state),
      isLocal: false,
      isSiren: true,
      uid: '',
      provider: sirenProvider,
      archiveMaskStrength: HudChrome.defaultArchiveMaskStrength,
      updaterAvailable: false,
    );

    final bool songPage = state.song != null &&
        (state.phase == BasicPhase.detail || state.phase == BasicPhase.lyrics);
    if (songPage) {
      final detail.SongDetailDrawing drawing = detail.renderSongDetail(
        _detailState(state),
        width,
        glyphs: ports,
        images: const _NoImages(),
      );
      sink.addDrawing(_commandRows(drawing.commands), drawing.hits);
      if (drawing.delegatedTo == detail.songDetailDelegateLyricsPanel) {
        final double x = width * 0.56;
        final double usable = width - x - 59;
        final lyrics.LyricsPanelDrawing panel = lyrics.paintLyricsPanel(
          _lyricsModel(state, x, usable),
          ports,
        );
        sink.addDrawing(panel.commands, panel.hits);
      }
    } else {
      _paintLibrary(sink, ports, state, width, portrait: portrait);
    }

    final player.PlayerBarDrawing bar = player.renderPlayerBar(
      _playerState(state),
      player.PlayerBarRect(0, height - player.playerBarRowHeight, width, player.playerBarRowHeight),
      dark,
      ports,
    );
    sink.addDrawing(bar.commands, bar.hits);

    _generation += 1;
    return BasicHudFrame(generation: _generation, commands: sink.commands, hits: sink.hits);
  }

  static void _paintLibrary(
    _HudSink sink,
    BasicGlyphPorts ports,
    BasicViewState state,
    double width, {
    required bool portrait,
  }) {
    final List<BasicListItem> items = basicLibraryItems(state);
    final int rawSelected = basicSelectedItemIndex(state, items);
    final int selected = items.isEmpty ? 0 : rawSelected.clamp(0, items.length - 1).toInt();
    final String currentId = items.isEmpty ? '' : _currentId(state, items[selected]);
    final String currentTitle = items.isEmpty ? '' : items[selected].title;
    final String currentArtist =
        items.isEmpty ? '' : _currentArtist(state, items[selected]);

    if (state.phase == BasicPhase.detail && state.album != null) {
      hudControl(sink, ports, '← 返回曲库', 59, 211, 280, 'back', dark: state.dark);
    }

    HudArchivePage(sink, ports, dark: state.dark).archive(
      width: width,
      s: HudArchiveState(
        libraryName: basicLibraryTitle(state),
        libraryIndex: selected,
        libraryTotal: items.length,
        selectedLane: 3,
        laneCount: 5,
        sourceOrderIndex: 2,
        provider: sirenProvider,
        isLocal: false,
        isSiren: true,
        directory: state.directory != null,
        directoryKind: state.directory?.kind,
        uid: '',
        restoringAccount: false,
        sourceLoading: state.loading,
        trackListMode: true,
        current: ArchiveItem(
          id: currentId,
          title: currentTitle.isEmpty ? sirenUnknownTitle : currentTitle,
          artist: currentArtist,
          kind: 'song',
        ),
        libraryItemsEmpty: items.isEmpty,
        libraryItemsLength: items.length,
        selectedPhysicalRow: selected,
        sourceMessage: state.status,
      ),
      drawTrackList: (double _, HudArchiveState __) {},
      drawEmpty: (double _, HudArchiveState __) {},
      supportsTrackList: (HudArchiveState _) => false,
    );

    if (items.isEmpty) {
      hudText(
        sink,
        state.error.isNotEmpty
            ? state.error
            : (state.status.isEmpty ? '塞壬唱片曲库为空' : state.status),
        59,
        500,
        20,
        dark: state.dark,
      );
      if (state.error.isNotEmpty || !state.loading) {
        hudControl(sink, ports, '重试', 59, 540, 200, 'retry', dark: state.dark);
      }
      return;
    }

    final List<ruler.TrackListItem> values = <ruler.TrackListItem>[
      for (final BasicListItem item in items) ruler.TrackListItem(title: item.title, kind: item.kind),
    ];
    void drawList(_HudSink target) {
      ruler.HudTrackRuler(target, ports, dark: state.dark, glyphBounds: ports).archiveTrackList(
        x: basicNavigationLeft(width),
        width: width,
        values: values,
        selected: selected,
        selectedTitle: currentTitle,
        /// 本版没有逐帧时钟：用 reduced-motion 的静止位置（不是假动画）。
        position: selected.toDouble(),
      );
    }

    if (portrait) {
      sink.shifted(0, basicPortraitListOffset, drawList);
    } else {
      drawList(sink);
    }

    if (state.error.isNotEmpty) {
      hudText(sink, state.error, 59, portrait ? 1120 : 40, 16, dark: state.dark);
    }
  }

  /// 选中行的歌手（Qt NativeHud.cpp:439-442 的 item.artist）：跟随高亮行自己的源，
  /// 不再借用 state.song/state.album（混排时两者可能指向别的条目）。
  static String _currentArtist(BasicViewState state, BasicListItem item) {
    if (item.kind == 'album' && item.index >= 0 && item.index < state.albums.length) {
      return state.albums[item.index].artist;
    }
    if (item.kind == 'song' && item.index >= 0 && item.index < state.songs.length) {
      return state.songs[item.index].artist;
    }
    return '';
  }

  static String _currentId(BasicViewState state, BasicListItem item) {
    if (item.kind == 'album' && item.index < state.albums.length) {
      return state.albums[item.index].id;
    }
    if (item.index < state.songs.length) {
      return state.songs[item.index].id;
    }
    return '';
  }

  static detail.SongDetailState _detailState(BasicViewState state) {
    final SirenSong? song = state.song;
    return detail.SongDetailState(
      provider: sirenProvider,
      officialPlayback: false,
      item: song == null
          ? null
          : detail.SongDetailItem(
              id: song.id,
              kind: 'song',
              title: song.title.isEmpty ? sirenUnknownTitle : song.title,
              artist: song.artist,
              artists: song.artist.isEmpty ? const <String>[] : <String>[song.artist],
              album: song.album,
              durationMs: song.durationMs,
              provider: sirenProvider,
            ),
      dark: state.dark,
      lyricsMode: state.phase == BasicPhase.lyrics,
      isSiren: true,
      providerName: basicLibraryName,
      uid: '',
      detailLoading: state.loading,
      player: detail.SongDetailPlayerState(
        currentIdentity: song == null ? null : 'siren:${song.id}',
        loading: state.buffering || state.loading,
        failed: state.playbackError.isNotEmpty,
      ),
      tracks: <detail.SongDetailTrack>[
        for (final SirenSong item in state.queue)
          detail.SongDetailTrack(
            id: item.id,
            title: item.title,
            artist: item.artist,
            durationMs: item.durationMs,
          ),
      ],
    );
  }

  static lyrics.LyricsPanelModel _lyricsModel(BasicViewState state, double x, double usable) {
    final SirenSong? song = state.song;
    final BasicLyricsDocument document = BasicLyricsDocument(
      lines: state.lyrics,
      offsetMs: 0,
      plainText: '',
      timed: state.lyrics.isNotEmpty,
    );
    return lyrics.LyricsPanelModel(
      x: x,
      width: usable,
      title: song?.title ?? '',
      artist: song?.artist ?? '',
      document: document.toLyricsDocument(),
      index: state.lyricIndex,
      status: state.lyricStatus,
      message: state.lyricMessage,
      seekable: state.durationMs > 0,
      provider: sirenProvider,
      isLocal: false,
      dark: state.dark,
    );
  }

  static player.PlayerBarState _playerState(BasicViewState state) {
    final SirenSong? song = state.song;
    return player.PlayerBarState(
      title: song?.title ?? '',
      artist: song?.artist ?? '',
      album: song?.album ?? '',
      status: state.playbackError.isNotEmpty ? state.playbackError : state.playerStatus,
      positionMs: state.positionMs,
      durationMs: state.durationMs,
      playing: state.playing,
      loading: state.buffering || state.loading,
      failed: state.playbackError.isNotEmpty,
      hasTrack: song != null,
      seekable: state.durationMs > 0,
      applicationVolume: false,
    );
  }
}

/// 3D 场景在 stage 坐标里的占位矩形（绘制与命中共用同一套 stage 约定）：
///  - 横屏：整窗（0,0,width,height）。Qt 的 Engine::resize 把场景按
///    `width / (height / 1080)`、1080 高舞台算投影（Qt/src/Engine.cpp:841-849），
///    也就是原 Qt 的 1728x1080 整幅；只给左栏会让 QQuickView 变成比 1 比 1 左右的
///    竖长视口，归档被压扁、详情抽出的唱片被裁。右栏文字可读性由 HudChrome 的
///    archiveMask 负责，不是靠缩小矩形；
///  - 竖屏：顶部 1080 设计高度（曲目列从 [basicPortraitListOffset] 开始，
///    所以这块区域本来就是空的，正好给 3D 场景）。
///
/// 只有尺寸退化（<320）时不挂载；是否选中曲目、是否已联网都不参与判断。
Rect? basicSceneStageRect({
  required bool portrait,
  required double width,
  required double height,
}) {
  final Rect rect = portrait
      ? Rect.fromLTWH(
          0,
          0,
          width,
          height < basicPortraitListOffset ? height : basicPortraitListOffset,
        )
      : Rect.fromLTWH(0, 0, width, height);
  if (rect.width < 320 || rect.height < 320) {
    return null;
  }
  return rect;
}

/// 命中/绘制共用外壳：CustomPaint 只重放本帧命令，手势层只解析命中。
class BasicHudSurface extends StatelessWidget {
  const BasicHudSurface({
    super.key,
    required this.state,
    required this.ports,
    required this.onAction,
    this.geometry,
    this.stage,
  });

  final BasicViewState state;
  final BasicGlyphPorts ports;
  final ValueChanged<String> onAction;

  /// 横屏由调用方按逻辑尺寸构造；竖屏用 PortraitStage 注入的 scope。
  final StageGeometry? geometry;
  final HudStage? stage;

  @override
  Widget build(BuildContext context) {
    final StageGeometry geometry = this.geometry ?? StageGeometryScope.of(context);
    final HudStage stage = this.stage ?? HudStageScope.of(context);
    final BasicHudFrame frame = BasicHudFrame.build(
      state: state,
      ports: ports,
      width: stage.width,
      height: stage.height,
      portrait: this.geometry == null,
    );
    final HudFrameEnvelope envelope = HudFrameEnvelope.decode(<String, Object?>{
      'generation': frame.generation,
      'frame': <String, Object?>{},
      'commands': frame.commands,
      'hits': <Object?>[for (final HudHit hit in frame.hits) hit.toJson()],
      'state': <String, Object?>{},
    });
    final bool portrait = this.geometry == null;
    final Rect? sceneRect = basicSceneStageRect(
      portrait: portrait,
      width: stage.width,
      height: stage.height,
    );
    final Widget? scene = sceneRect == null ? null : _scene(state, geometry, sceneRect, portrait: portrait);
    // 场景矩形已换算到本层坐标（竖屏在 stage 单位里、横屏在逻辑坐标里），
    // 原始指针搬运层要用它把设备坐标归一成 1080 高的舞台坐标。
    final Rect? rawSceneRect =
        sceneRect == null ? null : (portrait ? sceneRect : geometry.rectToLogical(sceneRect));
    return Stack(
      children: <Widget>[
        if (scene != null) scene,
        Positioned.fill(
          child: CustomPaint(
            painter: HudStagePainter(
              envelope: envelope,
              ports: HudPainterPorts(
                text: ports.draw,
                path: ports.pathFor,
                image: ports.imageFor,
              ),
              stage: stage,
            ),
          ),
        ),
        Positioned.fill(child: _tapLayer(geometry, frame, rawSceneRect)),
      ],
    );
  }

  /// HUD 的顶层点击层：既解析 HUD 命中，也把**原始**指针搬给 Qt 场景。
  ///
  /// 为什么搬指针：hybrid composition 下 Android 的原生派发到不了 Qt 子树
  /// （FlutterView 里 PlatformOverlayView 排在最后、先拿到事件；实测 QtSceneView
  /// 的 FrameLayout.dispatchTouchEvent 一次都不进），而本层 `translucent` 又让场景
  /// 子树永远不被命中——所以场景自己挂监听是收不到的，只能由这一层转发。
  /// 只转发原始 down/move/up/cancel，手势语义全部由 Qt 的 NativeSceneInput 决定。
  Widget _tapLayer(StageGeometry geometry, BasicHudFrame frame, Rect? rawSceneRect) {
    final Widget layer = GestureDetector(
      // translucent：空白处返回 false，命中链继续下探到原生 3D（WebView），
      // 但本层仍收到 tap 供 HUD 命中解析——两者不互相吞掉。
      behavior: HitTestBehavior.translucent,
      // 竖屏手势层在 PortraitStage 的 Transform.scale 里，localPosition 已经是
      // 舞台坐标；而 HitLayer/StageGeometry 的入口约定是窗口逻辑坐标（唯一换算
      // 收在 geometry.toStage 里）。这里先 toLogical 再交给 _dispatch，横屏的
      // Stack 本来就是逻辑坐标，原样传入。92 少这一步，竖屏命中被除了两次 scale。
      onTapUp: (TapUpDetails details) => _dispatch(
        geometry,
        frame,
        this.geometry == null ? geometry.toLogical(details.localPosition) : details.localPosition,
      ),
    );
    if (rawSceneRect == null) {
      return layer;
    }
    // Listener 在 GestureDetector 之外，先拿到原始事件，再交给手势识别器。
    // forwardAt：这一串手势是否归 Qt。只有"该点没有 HUD 命中目标"才归 Qt——
    // 否则点列表行/上下按钮/播放条时会顺带把 Qt 场景也拖一下（设备实测现象）。
    // 归属在按下时定下来并保持整串手势，不做中途翻转。
    final HitLayer hitLayer = HitLayer(
      geometry: geometry,
      android: defaultTargetPlatform == TargetPlatform.android,
    );
    return QtSceneRawPointerLayer(
      sceneRect: rawSceneRect,
      forwardAt: (Offset local) => hitLayer.hitAt(frame.hits, local) == null,
      child: layer,
    );
  }

  /// Qt 左侧是 3D 容器区；这里挂的是 Qt 自己的场景层（同进程 QQuickView，
  /// platform view），非 Android 平台由 [QtSceneView] 自己给出可见说明。
  ///
  /// 挂载不以网络、选中 id 或歌词页为前提：首页（刚启动的空曲库）同样有场景。
  /// 这里**不再**向场景传 songId/albumId/model——曲库、播放与相机都由 Qt 的 Engine
  /// 与场景层自己持有，Flutter 只提供矩形，避免两套状态各自跑一套动画。
  Widget _scene(
    BasicViewState state,
    StageGeometry geometry,
    Rect stageRect, {
    required bool portrait,
  }) {
    // 竖屏的 Stack 已在 stage 单位内（PortraitStage 的 Transform.scale）；
    // 横屏的 Stack 是逻辑像素：同一条 stage 矩形只换算一次，绝不双 scale。
    final Rect rect = portrait ? stageRect : geometry.rectToLogical(stageRect);
    return Positioned.fromRect(
      rect: rect,
      child: QtSceneView(state: state, onAction: onAction),
    );
  }

  void _dispatch(StageGeometry geometry, BasicHudFrame frame, Offset logical) {
    final HitLayer layer = HitLayer(
      geometry: geometry,
      android: defaultTargetPlatform == TargetPlatform.android,
    );
    final HudHit? hit = layer.hitAt(frame.hits, logical);
    if (hit == null) {
      return;
    }
    final bool seek = hit.action.startsWith('player:seek-fraction:');
    final bool volume = hit.action.startsWith('player:volume-fraction:');
    if (seek || volume) {
      final Offset stagePoint = geometry.toStage(logical);
      final String? action = HitLayer.playerFractionAction(
        control: seek ? 'seek' : 'volume',
        x: stagePoint.dx - hit.x,
        width: hit.width,
      );
      if (action != null) {
        onAction(action);
        return;
      }
    }
    onAction(hit.action);
  }
}

/// song_detail 的累加器按 Qt op 顺序把每条命令（本身是 List<Object?>）
/// 追加进 List<Object?>，静态类型比 [_HudSink] 的命令表宽一层。
/// 这里按原序逐条还原成命令表：不改顺序、不去重、不丢项；
/// 元素不是命令数组说明上游破坏契约，抛错而不是静默跳过。
List<List<Object?>> _commandRows(List<Object?> commands) {
  final List<List<Object?>> rows = <List<Object?>>[];
  for (var index = 0; index < commands.length; index++) {
    final Object? command = commands[index];
    if (command is List<Object?>) {
      rows.add(command);
    } else {
      throw StateError('song_detail command #$index is not a command array: $command');
    }
  }
  return rows;
}

/// Qt 的封面走 scene-draw 通道（songDetailCoverChannel）；本版没有图片端口，
/// 返回 null 让 song_detail 走自己的缺图分支，不用静态图冒充。
class _NoImages implements detail.SongDetailImagePort {
  const _NoImages();

  @override
  detail.SongDetailImage? image(String key) => null;
}

class _HudSink implements HudSurfaceSink {
  final List<List<Object?>> commands = <List<Object?>>[];
  final List<HudHit> hits = <HudHit>[];

  @override
  void op(List<Object?> command) => commands.add(command);

  @override
  void hit(HudHit hit) => hits.add(hit);

  /// 把页面/播放条产出的命令与命中并入本帧；命中地图走协议解码。
  void addDrawing(List<List<Object?>> drawn, List<Map<String, Object?>> rawHits) {
    commands.addAll(drawn);
    hits.addAll(decodeHudHits(rawHits).hits);
  }

  /// 竖屏重排：同一套 1080 设计的命令整体下移，命中同步平移，
  /// 绘制与命中仍是同一份坐标（不各自推导）。
  void shifted(double dx, double dy, void Function(_HudSink sink) draw) {
    final _HudSink inner = _HudSink();
    draw(inner);
    if (inner.commands.isEmpty) {
      return;
    }
    op(<Object?>['save']);
    if (dx != 0 || dy != 0) {
      op(<Object?>['translate', dx, dy]);
    }
    commands.addAll(inner.commands);
    op(<Object?>['restore']);
    for (final HudHit hit in inner.hits) {
      hits.add(HudHit(
        x: hit.x + dx,
        y: hit.y + dy,
        width: hit.width,
        height: hit.height,
        action: hit.action,
        label: hit.label,
        fixed: hit.fixed,
      ));
    }
  }
}
