import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, visibleForTesting;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart' show Ticker;

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

// 列表真值（BasicListItem / basicLibraryItems / basicSelectedItemIndex）住在
// basic_models.dart：controller 选曲与 HUD 绘制/命中必须用同一份顺序，
// 所以这里只做再导出，保持既有 import 站点不变。
export 'basic_models.dart' show BasicListItem, basicLibraryItems, basicSelectedItemIndex;

/// 资料库名（Qt NativeHud.cpp:380 的 "MUSIC DATABASE / <libraryName>"）。
const String basicLibraryName = '塞壬唱片';

/// 竖屏重排时，曲目列从 1080 设计高度之后开始（stage unit）。
const double basicPortraitListOffset = 1080.0;

/// 侧栏起点：Qt NativeHud.cpp:408 `navigationLeft(width) = width - 789`。
double basicNavigationLeft(double width) => width - 789;

/// 资料库标题（Qt MusicLibrary::libraryName()，Qt/src/MusicLibrary.cpp:188-193）：
/// 目录打开时是目录标题（'全部歌曲'），否则是**当前列名**（`columns.value(lane)`：
/// 搜索结果 / 喜欢的歌曲 / 我的歌单 / 全部歌曲 / 全部专辑）。
String basicLibraryTitle(BasicViewState state) {
  final BasicDirectory? directory = state.directory;
  if (directory != null) {
    // Qt/src/MusicLibrary.cpp:189-193：目录内就是 directory->item["title"]。
    // 目录确实可能没标题（来源没给），那时回落到 provider 名——不编造标题，
    // 也不拿根列的列名冒充目录名（目录不是列）。
    return directory.title.isEmpty ? basicLibraryName : directory.title;
  }
  final String lane = basicLaneName(state.selectedLane);
  return lane.isEmpty ? basicLibraryName : lane;
}

/// 一帧的扁平命令流 + 命中集合。绘制（HudStagePainter）与命中（HitLayer）
/// 消费同一份，禁止各自再推导坐标。
class BasicHudFrame {
  BasicHudFrame({
    required this.generation,
    required this.commands,
    required this.hits,
    this.animating = false,
  });

  final int generation;
  final List<List<Object?>> commands;
  final List<HudHit> hits;

  /// 本帧绘制结束后，共享滚动文字是否仍有字符槽在动。宿主
  /// （[BasicHudSurface]）据此续帧；静止帧为 false，不空转 ticker。
  final bool animating;

  static int _generation = 0;

  static BasicHudFrame build({
    required BasicViewState state,
    required BasicGlyphPorts ports,
    required double width,
    required double height,
    required bool portrait,
    /// 拖动中的临时滚动位置（条目单位）；null = 用 state.listPosition。
    double? listPosition,
    /// 本帧的共享滚动文字时钟（秒，与 kReelDuration 同单位）。宿主 ticker 推进；
    /// 缺省 0 时首帧仍会画静态文字（RollingLabel 首帧 alpha=1），不会空白。
    double animationTime = 0,
    /// 是否让值变化走卷动动画；false 时滚动标签退化为单条静态 text。
    ///
    /// 默认 **false**：没有帧时钟的调用点（离屏/测试逐帧构造）必须拿到与旧行为
    /// 同形的单条 text 命令（如整条歌名），不能因为它们不推进时间就把文字拆成
    /// 逐字槽或整段不画。宿主 [BasicHudSurface] 有 ticker，显式传 true。
    bool animateText = false,
  }) {
    final _HudSink sink = _HudSink();
    final bool dark = state.dark;
    // 本帧绑定：滚动标签与静态 hudText 走同一个 sink、同一发射顺序，
    // ink 取同一 hudInk(dark)，暗/亮主题不会画出两套颜色。
    ports.beginFrame(
      sink: sink,
      time: animationTime,
      ink: hudInk(dark),
      animate: animateText,
    );
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
      _paintLibrary(
        sink,
        ports,
        state,
        width,
        portrait: portrait,
        listPosition: listPosition,
      );
    }

    final player.PlayerBarDrawing bar = player.renderPlayerBar(
      _playerState(state),
      player.PlayerBarRect(0, height - player.playerBarRowHeight, width, player.playerBarRowHeight),
      dark,
      ports,
    );
    sink.addDrawing(bar.commands, bar.hits);

    final bool animating = ports.endFrame();
    _generation += 1;
    return BasicHudFrame(
      generation: _generation,
      commands: sink.commands,
      hits: sink.hits,
      animating: animating,
    );
  }

  static void _paintLibrary(
    _HudSink sink,
    BasicGlyphPorts ports,
    BasicViewState state,
    double width, {
    required bool portrait,
    double? listPosition,
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
        // 真实列：Qt `selectedLane` / `sourceOrder().indexOf(selectedLane)` /
        // columns.size()（Qt/src/NativeHud.cpp:479-490 的 COLLECTION xx / 05）。
        selectedLane: state.selectedLane.clamp(0, basicSirenColumns.length - 1).toInt(),
        laneCount: basicSirenColumns.length,
        sourceOrderIndex: basicSourceOrderIndex(state.selectedLane),
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
          // 真实条目类型：专辑列（lane 4）的行是 album，不当 song 冒充。
          kind: items.isEmpty ? 'song' : items[selected].kind,
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
            // 空列文案按列区分（账号列不假装已加载、检索列提示输入关键词）。
            : (state.status.isEmpty
                ? basicLaneEmptyNotice(
                    state.selectedLane,
                    // 「喜欢/歌单」列的空态必须同时看端口可用性与未解析条数：
                    // 端口没接上 ≠ 收藏是空的（basic_models.dart:531-538）。
                    localCollectionsAvailable: state.localCollectionsAvailable,
                    unresolvedLikedIds: state.localUnresolvedLikedIds,
                  )
                : state.status),
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
        /// 滚动窗口是连续量（条目单位）：静止时由 state.listPosition 决定
        /// （= 选中行），拖动时由手指位移临时覆盖。position 与 selected 分开传，
        /// 高亮永远跟选中走，不跟窗口走。外部状态没给窗口时跟随选中（旧行为）。
        position: listPosition ?? state.listPosition ?? selected.toDouble(),
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

  /// 测试入口：右栏高亮行的身份 id（与绘制/封面共用同一个函数）。
  @visibleForTesting
  static String currentIdForTest(BasicViewState state, BasicListItem item) =>
      _currentId(state, item);

  static String _currentId(BasicViewState state, BasicListItem item) {
    if (item.kind == 'album' && item.index < state.albums.length) {
      return state.albums[item.index].id;
    }
    // 歌单行的身份来自行自己（BasicListItem.id），不能拿 state.songs[item.index] 顶——
    // 「我的歌单」列里没有曲目，按下标回落到曲库会给出另一首歌的 id（132R D2）。
    if (item.kind == 'playlist') {
      return item.id;
    }
    if (item.kind == 'song' && item.index < state.songs.length) {
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
    // 播放条只报**真正在播**的曲目（state.playingTrack），不拿选中曲目冒充：
    // 选中可以没有播放，播放条不该显示一首没在播的歌。
    final SirenSong? song = state.playingTrack;
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
///    archiveMask 负责（本文件 :75 `suppressMask: false`），不是靠缩小矩形；
///    984 只是 HUD 内容带的高度（Qt/src/NativeHud.cpp:324-325 `clip(0, 0, width,
///    984)`），不是场景视口——把它当场景矩形会把 1080 高的舞台压成 984/1080 的
///    比例，再靠改 fov/eye 去"修"，那是掩盖视口错，不是修；

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

/// 曲目列在 stage 坐标里的手势区域（拖动/点选只在这块参与手势竞技场）。
///
/// 常量取自 ruler 自己的裁剪窗口（lib/hud/widgets/track_ruler.dart 的 titleY=509、
/// 上下各 290、高 610），绘制与手势共用一处，手势层不再自己拍一套坐标。
Rect basicLibraryListStageRect({required bool portrait, required double width}) {
  final double rawLeft = basicNavigationLeft(width) - 4;
  final double left = rawLeft < 0 ? 0 : rawLeft;
  final double right = width < left ? left : width;
  return Rect.fromLTWH(
    left,
    509 - 290 + (portrait ? basicPortraitListOffset : 0),
    right - left,
    610,
  );
}

/// HUD 自己的触摸区域（stage 坐标，闭区间）：每个命中形状（含 android 的触控
/// 余量，口径与 [HitLayer.effectiveRect] 同一处）＋曲目列矩形。
///
/// 这是「谁消费这条指针」的唯一真值：HUD 手势层用它决定 hitTest，原生 raw
/// pointer 适配层也必须用它在 **down 时**决定 ownership（命中这里＝HUD 消费整条
/// 指针序列，不转发给 Qt；否则＝场景消费，转发 Qt 并捕获到终止事件）。
///
/// 与 [BasicHudSurface] 共用同一个 [frame]：绘制、点选、ownership 三者不会各自
/// 推导出不同的命中地图。坐标空间只有一种——舞台坐标（横屏 0..width / 0..984，
/// 竖屏 0..1080 见 [basicSceneStageRect]），不做第二次换算。
List<Rect> basicHudRegionRects(
  BasicHudFrame frame, {
  required StageGeometry geometry,
  required bool android,
  required bool portrait,
  required double width,
}) {
  final HitLayer layer = HitLayer(geometry: geometry, android: android);
  return <Rect>[
    for (final HudHit hit in frame.hits) layer.effectiveRect(hit),
    basicLibraryListStageRect(portrait: portrait, width: width),
  ];
}

/// 同上，但自己起一帧：给不持有 [frame] 的调用方（原生适配层的 ownership
/// 判定、测试）用。命中地图仍然只有一份来源（[BasicHudFrame.build]）。
List<Rect> basicHudOwnedStageRects({
  required BasicViewState state,
  required BasicGlyphPorts ports,
  required StageGeometry geometry,
  required double width,
  required double height,
  required bool portrait,
  bool android = false,
  double? listPosition,
}) {
  final BasicHudFrame frame = BasicHudFrame.build(
    state: state,
    ports: ports,
    width: width,
    height: height,
    portrait: portrait,
    listPosition: listPosition,
  );
  return basicHudRegionRects(
    frame,
    geometry: geometry,
    android: android,
    portrait: portrait,
    width: width,
  );
}

/// 这条 stage 坐标的指针是否归 HUD 消费（闭区间，与 [HitLayer.containsClosed]
/// 同一约定：右/下边界也算命中）。
bool basicHudOwnsStagePoint(
  Offset stagePoint, {
  required List<Rect> regions,
}) {
  for (final Rect rect in regions) {
    if (stagePoint.dx >= rect.left &&
        stagePoint.dx <= rect.right &&
        stagePoint.dy >= rect.top &&
        stagePoint.dy <= rect.bottom) {
      return true;
    }
  }
  return false;
}

/// HUD 手势层：只在 [regions] 给的矩形内参与命中，矩形外返回 false。
///
/// 这是“不抢 Qt 触摸”的关键：Stack 命中链在返回 true 的子节点处停下，旧实现用
/// `Positioned.fill` + translucent 的 GestureDetector 恒返回 true，于是 Qt 的
/// PlatformView 永远收不到 touch（唱片区域左右拖动不到 Qt 的机制原因）。
/// 现在只有 HUD 自己画出来的命中形状（含 android 的 16 stage 单位触控余量）和
/// 曲目列矩形参与手势，其余位置的触摸原样下探给 PlatformView。
class _HudGestureRegion extends SingleChildRenderObjectWidget {
  const _HudGestureRegion({required this.regions, required Widget super.child});

  final List<Rect> regions;

  @override
  _RenderHudGestureRegion createRenderObject(BuildContext context) =>
      _RenderHudGestureRegion(regions);

  @override
  void updateRenderObject(BuildContext context, _RenderHudGestureRegion renderObject) {
    renderObject.regions = regions;
  }
}

class _RenderHudGestureRegion extends RenderProxyBox {
  _RenderHudGestureRegion(this.regions);

  List<Rect> regions;

  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) {
    for (final Rect rect in regions) {
      // 闭区间：与 HitLayer.containsClosed 同一约定（右/下边界也算命中）。
      if (position.dx >= rect.left &&
          position.dx <= rect.right &&
          position.dy >= rect.top &&
          position.dy <= rect.bottom) {
        return super.hitTest(result, position: position);
      }
    }
    return false;
  }
}

/// 只允许从曲目列开始的竖直拖动（其它位置不参与竞技场，也就不会跟 Qt 抢手势）。
class _LibraryDragRecognizer extends VerticalDragGestureRecognizer {
  _LibraryDragRecognizer({this.allows, super.debugOwner});

  bool Function(Offset local)? allows;

  @override
  bool isPointerAllowed(PointerEvent event) {
    final bool Function(Offset local)? check = allows;
    if (check != null && !check(event.localPosition)) {
      return false;
    }
    return super.isPointerAllowed(event);
  }
}

/// 命中/绘制共用外壳：CustomPaint 只重放本帧命令，手势层只解析命中。
class BasicHudSurface extends StatefulWidget {
  const BasicHudSurface({
    super.key,
    required this.state,
    required this.ports,
    required this.onAction,
    this.onLibraryScroll,
    this.onLibraryScrollUpdate,
    this.geometry,
    this.stage,
    this.sceneKey,
  });

  final BasicViewState state;
  final BasicGlyphPorts ports;
  final ValueChanged<String> onAction;

  /// 列表拖动结束的落点（条目单位，可含小数）；由 basic_app 接到
  /// BasicController.commitLibraryScroll。null = 只支持点选，不支持拖动。
  final ValueChanged<double>? onLibraryScroll;

  /// 拖动中的连续窗口位置（条目单位，可含小数）。Q3 双向跟随契约：
  /// 抬手前必须多次回调（每次指针 move 一次），供宿主把列表窗口实时投影到
  /// 3D 层（BasicApp -> controller.listPosition -> Qt 场景）。只读位置：
  /// 不播放、不换队列、不改选中之外的任何状态；抬手落点仍走 [onLibraryScroll]。
  final ValueChanged<double>? onLibraryScrollUpdate;

  /// 横屏由调用方按逻辑尺寸构造；竖屏用 PortraitStage 注入的 scope。
  final StageGeometry? geometry;
  final HudStage? stage;

  /// 场景层（Qt platform view）的身份键：横竖屏切换时由上层传入**同一个** key，
  /// 让 PlatformView 的 element 被移动（reparent）而不是销毁重建——否则旋转会
  /// 重新创建 QQuickView 并重启场景/Node，播放与相机都会断。
  final Key? sceneKey;

  @override
  State<BasicHudSurface> createState() => _BasicHudSurfaceState();
}

class _BasicHudSurfaceState extends State<BasicHudSurface>
    with SingleTickerProviderStateMixin {
  /// 拖动中的临时滚动位置（条目单位）；null = 跟随 state.listPosition。
  double? _dragPosition;

  /// ruler 相邻两项的中心距（lib/hud/widgets/track_ruler.dart 的 88/52 布局，
  /// 相邻为 88）；拖动换算用同一常量，避免手感与绘制不一致。
  static const double _rowStep = 88;

  /// 共享滚动文字的帧时钟（秒）。只由 [_rollingTicker] 单调推进，不跟触摸绑定：
  /// 初始/暂停/不触摸时标签也会走到可见终态（见 lib/hud/text/rolling_text.dart）。
  double _animationTime = 0;

  /// ticker 的单调累加基准：Ticker.start() 会把 elapsed 归零重来，直接当时间用会
  /// 让字符槽"倒放"，所以只在两次 tick 之间取增量再累加。
  Duration? _tickerBase;
  Ticker? _rollingTicker;
  bool _rollingAnimating = false;

  @override
  void initState() {
    super.initState();
    // 端口里的 RollingLabel 可能比本 State 活得久（端口随 resources 复用），
    // 它们的动画曲线记的是旧时钟；新 State 若从 0 起算，旧曲线会被当成"仍在动"
    // 而空转 ticker。接上端口的当前帧时钟，保证同一时间基准。
    _animationTime = widget.ports.rollingText.time;
    _rollingTicker = createTicker(_onRollingTick);
  }

  @override
  void dispose() {
    // 释放 ticker 并解绑：避免已卸载的 state 继续 setState，也保证外部
    // state.listPosition 不会被残留的 _dragPosition 遮住。
    _rollingTicker?.dispose();
    _rollingTicker = null;
    _dragPosition = null;
    super.dispose();
  }

  void _onRollingTick(Duration elapsed) {
    final Duration? base = _tickerBase;
    _tickerBase = elapsed;
    if (base == null || !mounted) {
      return;
    }
    final double delta =
        (elapsed - base).inMicroseconds / Duration.microsecondsPerSecond;
    if (delta <= 0) {
      return;
    }
    setState(() => _animationTime += delta);
  }

  /// 本帧结束后是否继续 ticker。在 build 里不能直接 start/stop，post-frame 生效。
  void _scheduleRollingTicker(bool animating) {
    if (animating == _rollingAnimating &&
        (!animating || (_rollingTicker?.isActive ?? false))) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((Duration _) {
      if (!mounted) {
        return;
      }
      if (animating) {
        if (!(_rollingTicker?.isActive ?? false)) {
          _tickerBase = null;
          _rollingTicker?.start();
        }
      } else {
        _rollingTicker?.stop();
      }
      _rollingAnimating = animating;
    });
  }

  @override
  Widget build(BuildContext context) {
    final StageGeometry geometry = widget.geometry ?? StageGeometryScope.of(context);
    final HudStage stage = widget.stage ?? HudStageScope.of(context);
    final bool portrait = widget.geometry == null;
    final BasicViewState state = widget.state;
    final BasicHudFrame frame = BasicHudFrame.build(
      state: state,
      ports: widget.ports,
      width: stage.width,
      height: stage.height,
      portrait: portrait,
      listPosition: _dragPosition,
      animationTime: _animationTime,
      animateText: true,
    );
    // 共享滚动文字有字符槽还在 kReelDuration 内 -> 续帧；静止后停 ticker。
    _scheduleRollingTicker(frame.animating);
    final HudFrameEnvelope envelope = HudFrameEnvelope.decode(<String, Object?>{
      'generation': frame.generation,
      'frame': <String, Object?>{},
      'commands': frame.commands,
      'hits': <Object?>[for (final HudHit hit in frame.hits) hit.toJson()],
      'state': <String, Object?>{},
    });
    final Rect? sceneRect = basicSceneStageRect(
      portrait: portrait,
      width: stage.width,
      height: stage.height,
    );
    final Widget? scene = sceneRect == null
        ? null
        : _scene(state, geometry, sceneRect, portrait: portrait);
    // 场景矩形已换算到本层坐标（竖屏在 stage 单位里、横屏在逻辑坐标里），
    // 原始指针搬运层要用它把设备坐标归一成 1080 高的舞台坐标。
    final Rect? rawSceneRect =
        sceneRect == null ? null : (portrait ? sceneRect : geometry.rectToLogical(sceneRect));

    final Rect listStageRect = basicLibraryListStageRect(
      portrait: portrait,
      width: stage.width,
    );
    // 命中矩形（stage 单位，已含触控余量）+ 曲目列；竖屏本层就在 stage 单位里，
    // 横屏本层是逻辑像素，统一在这里换算一次（HitLayer 内部同理只换一次）。
    // 区域集合由 [basicHudRegionRects] 给出：手势层与原生 ownership 判定同源。
    final List<Rect> stageRegions = basicHudRegionRects(
      frame,
      geometry: geometry,
      android: defaultTargetPlatform == TargetPlatform.android,
      portrait: portrait,
      width: stage.width,
    );
    final List<Rect> regions = portrait
        ? stageRegions
        : <Rect>[for (final Rect rect in stageRegions) geometry.rectToLogical(rect)];
    final Rect listRect = portrait ? listStageRect : geometry.rectToLogical(listStageRect);
    return Stack(
      children: <Widget>[
        if (scene != null) scene,
        Positioned.fill(
          child: CustomPaint(
            painter: HudStagePainter(
              envelope: envelope,
              ports: HudPainterPorts(
                text: widget.ports.draw,
                path: widget.ports.pathFor,
                image: widget.ports.imageFor,
              ),
              stage: stage,
            ),
          ),
        ),
        Positioned.fill(
          // 唯一一条指针消费路径：外层 [QtSceneRawPointerLayer] 在 down 时用 HUD
          // 自己的区域图（[basicHudRegionRects]，含列表行与 android 触控余量）
          // 定归属，内层 [_HudGestureRegion] 用同一份 regions 决定谁参与命中。
          // 于是每一条指针序列只有一个消费者：落在 HUD 上＝整串归 HUD（场景不跟着
          // 动），落在别处＝整串归 Qt（HUD 不抢），中途不翻转。
          child: rawSceneRect == null
              ? _hudGestureLayer(frame, geometry, portrait, regions, listRect)
              : QtSceneRawPointerLayer(
                  sceneRect: rawSceneRect,
                  forwardAt: (Offset local) =>
                      !basicHudOwnsStagePoint(local, regions: regions),
                  child: _hudGestureLayer(frame, geometry, portrait, regions, listRect),
                ),
        ),
      ],
    );
  }

  /// HUD 的手势层：点选解析 + 曲目列拖动，只在 [regions] 内参与命中。
  ///
  /// 为什么不再用 `Positioned.fill` + translucent 的 GestureDetector：那会恒返回
  /// true，Qt 的 PlatformView 永远收不到 touch（唱片左右拖不动的机制原因）。
  Widget _hudGestureLayer(
    BasicHudFrame frame,
    StageGeometry geometry,
    bool portrait,
    List<Rect> regions,
    Rect listRect,
  ) {
    return _HudGestureRegion(
      regions: regions,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        // 竖屏手势层在 PortraitStage 的 Transform.scale 里，localPosition 已经是
        // 舞台坐标；而 HitLayer/StageGeometry 的入口约定是窗口逻辑坐标（唯一换算
        // 收在 geometry.toStage 里）。这里先 toLogical 再交给 _dispatch，横屏的
        // Stack 本来就是逻辑坐标，原样传入。92 少这一步，竖屏命中被除了两次 scale。
        onTapUp: (TapUpDetails details) => _dispatch(
          geometry,
          frame,
          portrait ? geometry.toLogical(details.localPosition) : details.localPosition,
        ),
        child: RawGestureDetector(
          behavior: HitTestBehavior.opaque,
          gestures: <Type, GestureRecognizerFactory>{
            _LibraryDragRecognizer:
                GestureRecognizerFactoryWithHandlers<_LibraryDragRecognizer>(
              () => _LibraryDragRecognizer(debugOwner: this),
              (_LibraryDragRecognizer recognizer) {
                recognizer.allows = (Offset local) => _inClosed(listRect, local);
                recognizer.onStart = (DragStartDetails details) =>
                    _dragStarted(widget.state);
                recognizer.onUpdate = (DragUpdateDetails details) =>
                    _dragUpdated(geometry, portrait, details);
                recognizer.onEnd = (DragEndDetails details) => _dragEnded();
                recognizer.onCancel = _dragEnded;
              },
            ),
          },
          child: const SizedBox.expand(),
        ),
      ),
    );
  }

  static bool _inClosed(Rect rect, Offset point) {
    return point.dx >= rect.left &&
        point.dx <= rect.right &&
        point.dy >= rect.top &&
        point.dy <= rect.bottom;
  }

  void _dragStarted(BasicViewState state) {
    final double start = _windowOf(state);
    setState(() => _dragPosition = start);
    // 起点也发一次：3D/原生层从当前窗口接上，第一次 move 之前就不会跳。
    widget.onLibraryScrollUpdate?.call(start);
  }

  /// 当前滚动窗口（条目单位）：显式位置优先，其次跟随选中，与 painter 同一规则。
  static double _windowOf(BasicViewState state) {
    final double? explicit = state.listPosition;
    if (explicit != null) {
      return explicit;
    }
    final List<BasicListItem> items = basicLibraryItems(state);
    return items.isEmpty ? 0 : basicSelectedItemIndex(state, items).toDouble();
  }

  void _dragUpdated(
    StageGeometry geometry,
    bool portrait,
    DragUpdateDetails details,
  ) {
    final double? current = _dragPosition;
    if (current == null) {
      return;
    }
    final int count = basicLibraryItems(widget.state).length;
    if (count == 0) {
      return;
    }
    // 手指向下 = 内容下移 = 窗口回退到更小的条目号（Qt ruler 的 position 语义）。
    final double unit = portrait ? _rowStep : _rowStep * geometry.stageScale;
    final double next = current - details.delta.dy / unit;
    final double max = (count - 1).toDouble();
    final double clamped = next < 0 ? 0 : (next > max ? max : next);
    setState(() => _dragPosition = clamped);
    // Q3 双向连续跟随：抬手前每个 move 都发一次连续条目位置。宿主把它投影到
    // 3D/原生层；这里只报告窗口，不选中、不播放、不改队列（落点仍由
    // _dragEnded 的 onLibraryScroll 提交）。
    widget.onLibraryScrollUpdate?.call(clamped);
  }

  void _dragEnded() {
    final double? ended = _dragPosition;
    if (ended == null) {
      return;
    }
    setState(() => _dragPosition = null);
    // 落点只**选中**：不播放、不换队列（Qt 的 archive 选中无播放副作用）。
    widget.onLibraryScroll?.call(ended);
  }

  /// Qt 左侧是 3D 容器区；这里挂的是 Qt 自己的场景层（同进程 QQuickView，
  /// platform view），非 Android 平台由 [QtSceneView] 自己给出可见说明。
  ///
  /// 挂载不以网络、选中 id 或歌词页为前提：首页（刚启动的空曲库）同样有场景。
  /// 曲库、播放与相机仍由 Qt 的 Engine 与场景层自己持有；这里只把**同一份**
  /// [BasicViewState] 与 HUD 的动作回调交给场景层（132R 的 QtSceneView 契约），
  /// 不另起第二套状态、也不用 song-key 重建视图。
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
      child: QtSceneView(
        key: widget.sceneKey,
        state: state,
        onAction: widget.onAction,
      ),
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
        widget.onAction(action);
        return;
      }
    }
    widget.onAction(hit.action);
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
