import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
// Factory<T> 来自 package:flutter/foundation.dart（dart:core 的 typedef），
// gestures.dart 只导出 OneSequenceGestureRecognizer 这类具体识别器。
import 'package:flutter/gestures.dart' show OneSequenceGestureRecognizer;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show PlatformViewHitTestBehavior;
import 'package:flutter/services.dart'
    show
        AndroidViewController,
        MethodCall,
        MethodChannel,
        MissingPluginException,
        PlatformException,
        PlatformViewController,
        PlatformViewsService;

import 'basic_models.dart';

/// PARITY QT-OVERLAY-128 — 把本仓库 **Qt 自己的场景层**挂进 Flutter 页面。
///
/// 这里不是近似重写，也不是"看起来像 3D"的东西：
///  * 原生实现是 Qt 的 `QQuickView`（材质、改过的模型、相机、归档布局、抽出返回、
///    触摸与动画全部由 Qt 的 RhiScene/NativeScene* 负责），在同一个进程里创建；
///  * Java 对端是 org.qtproject.qt.android.RhineQtView extends QtView
///    （android/app/src/main/java/org/qtproject/qt/android/RhineQtView.java），
///    它把 QQuickView 的窗口挂到 Flutter 的 platform view 上；
///  * 本文件只负责三件事：给这块原生视图一个矩形、把 [BasicViewState] 的**渲染相关
///    子集**推给 Qt、把 Qt 侧产生的动作回传给调用方。不复制相机/HUD，不建第二套曲库。
///
/// 必须用 hybrid composition（[PlatformViewsService.initExpensiveAndroidView]）：
/// Qt 的 `QtWindow` 内部是真 `SurfaceView`（QtSurface），纹理层合成拿不到它，
/// 而 hybrid composition 把原生视图放进同一棵 Android 视图树——触摸因此走 Android
/// 自己的派发路径到 QtView/W 层。
///
/// 非 Android 平台给显式说明（不渲染模型、不伪造旋转动画）。
const String qtSceneViewType = 'rhine/qt_scene';

/// Dart ↔ 原生（Qt 场景）的唯一通道。
///
/// 原生 → Dart 只有两类调用：`action`（Qt 侧产生的动作，如选中/打开查看页）与
/// 诊断回执；Dart → 原生只有 `state`（场景渲染状态快照）。播放权威不在 Qt：
/// 移动端 main.cpp 只在非 RHINE_MOBILE 下建 PlaybackConnection，所以通道里
/// 不传任何播放指令。
const String qtSceneChannelName = 'rhine.music/qt_scene';

/// 只有 Android 有真正的 Qt 视图实现。
bool get qtScenePlatformSupported =>
    !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

String qtScenePlatformLabel() => kIsWeb ? 'Web' : defaultTargetPlatform.name;

const Color _sceneBackground = Color(0xFF11181B);
const Color _sceneText = Color(0xFFE7E0D7);
const Color _sceneMuted = Color(0xFF98A2A6);

/// Qt 场景的模式词表：与 Qt 的 NativeScene::setMode 同词（'archive' / 'detail'）。
///
/// lyrics 页在 Qt 侧同样是"选中曲目的唱片/详情"这一层，所以映射到 detail。
/// boot（还没进页面）时给 archive：Qt 的启动曲线（NativeApplication::initialize）
/// 在没有首次启动动画时本来就走 archive。
String qtSceneModeOf(BasicViewState state) {
  switch (state.phase) {
    case BasicPhase.detail:
    case BasicPhase.lyrics:
      return 'detail';
    case BasicPhase.boot:
    case BasicPhase.library:
      return 'archive';
  }
}

/// 选中条目在**当前可见列表**里的行号（-1 = 不在列表里/没有选中）。
///
/// 只认选中身份 [BasicViewState.selection]，不看播放：播放状态是
/// BasicViewState.playing/positionMs，与"用户此刻浏览到哪"是两件事。
///
/// 必须是"列表行号"，不能是"曲目在 state.songs 里的下标"：
/// `EmbeddedSceneHost.cpp:455` 拿到这个值直接 `scene.select(index, cell)`
/// （注释写明「index 是 Flutter 的列表行号」）。旧实现只查 state.songs，
/// 于是「全部专辑」列（选中的是专辑行、state.song 被清空）永远返回 -1，
/// Qt 侧一直不 select ⇒ 列表滚动只有镜头在动、高亮模型不换列（用户实测缺陷）。
/// 这里改成先在 [basicLibraryItems] 里按 (kind,id) 找行号，专辑行/歌曲行同一套。
int qtSceneSelectedIndexOf(BasicViewState state) {
  final List<BasicListItem> items = basicLibraryItems(state);
  if (items.isEmpty) {
    return -1;
  }
  final BasicSelection? selection = state.selection;
  if (selection != null) {
    for (var position = 0; position < items.length; position++) {
      final BasicListItem item = items[position];
      if (item.kind == selection.kind && item.id == selection.id) {
        return position;
      }
    }
  }
  // 兼容没有 selection 的旧调用点：仍按选中曲目的身份在列表里找行号。
  final SirenSong? song = state.song;
  if (song != null) {
    for (var position = 0; position < items.length; position++) {
      final BasicListItem item = items[position];
      if (item.kind != 'song' || item.index < 0 || item.index >= state.songs.length) {
        continue;
      }
      if (state.songs[item.index].id == song.id) {
        return position;
      }
    }
  }
  return -1;
}

/// 推给 Qt 的状态快照（JSON 字符串）。
///
/// 只放 Qt 真正会用的键；未知键由 Qt 侧忽略。键的语义：
///  * `v`：协议版本；
///  * `dark`：主题（Qt 场景的雾底/材质明暗）；
///  * `mode`：'archive' | 'detail'；
///  * `index`：选中行（-1 = 无）；Qt 用来 select(index) 归档槽位；
///  * `key`：材质/封面身份键（SirenSong.key）。**没有选中就不带这个键**：
///    Qt 侧据此 musicClear()，不留上一首的旧封面。
///  * `count`：当前列表长度（Qt 侧只用于诊断/范围校验，不建第二套曲库）。
/// 选中项的真实封面 URL：歌曲自带 cover 优先；没有就用**同一张专辑**的封面。
///
/// 塞壬的 `/api/songs` 条目不保证带封面，专辑封面在 `/api/albums` 上（Qt 侧 detail 页
/// 的盘面也是专辑封面）。这里只做"同一个真实标识的另一种取法"，不造数据、不查账号。
String qtSceneCoverOf(BasicViewState state, SirenSong song) {
  if (song.cover.isNotEmpty) {
    return song.cover;
  }
  for (final SirenAlbum album in state.albums) {
    if (album.id == song.albumId) {
      return album.cover;
    }
  }
  return '';
}

/// 单格条目的真实封面：条目自带图优先；歌曲没有自带图时只允许回退到**同一张专辑**
/// 的封面（`state.albums` 里 `albumId` 相等的那一张），与 [qtSceneCoverOf] 同一条规则。
///
/// 不做的事：不按 filtered index 去 state.songs 里翻、不跨条目借图、不造占位 URL。
/// 拿不到就返回空串——Qt 侧（EmbeddedCellResources）据此走 honest placeholder。
String qtSceneCellCoverOf(BasicViewState state, BasicListItem item) {
  if (item.cover.isNotEmpty) {
    return item.cover;
  }
  if (item.kind != 'song' || item.albumId.isEmpty) {
    return '';
  }
  for (final SirenAlbum album in state.albums) {
    if (album.id == item.albumId) {
      return album.cover;
    }
  }
  return '';
}

/// 一列身份用的稳定散列（FNV-1a 32 位，逐条逐字符）。
///
/// 为什么不用 Dart 的 `Object.hash` / `hashCode`：字符串的 hashCode 在 VM 上带随机种子
/// （每次进程启动不同），指纹会跨进程漂移，设备日志里的"同一份集合"无法复现比较；而且
/// `List.hashCode` 是同一性散列，对内容不做任何承诺。这里自己算，纯函数、无随机种子、
/// 对**顺序**敏感（相邻两条对调一定变）。
int _qtSceneLaneHash(List<BasicListItem> lane) {
  int hash = 0x811c9dc5;
  for (int i = 0; i < lane.length; i++) {
    final BasicListItem item = lane[i];
    final String identity = '${item.kind}\u0000${item.key}';
    for (int j = 0; j < identity.length; j++) {
      hash ^= identity.codeUnitAt(j);
      hash = (hash * 0x01000193) & 0xFFFFFFFF;
    }
    // 分隔符参与散列：否则 "ab"+"c" 与 "a"+"bc" 在同一列里会撞成同一个值。
    hash ^= 0x1f;
    hash = (hash * 0x01000193) & 0xFFFFFFFF;
  }
  return hash;
}

/// 一列条目的**完整有序身份**：长度 + 全量顺序散列 + 首末 key。
///
/// 旧实现只写 `length:first:last`，于是"中间两条对调、条数不变、首末不变"这类集合变化
/// 完全不可见 —— 交互代次不递增，Qt 侧仍把它当成同一份上下文的迟到输入，而画面已经被
/// 换成了新顺序。首末 key 现在只是便于人工判读的冗余信息（设备日志里能看出是哪一列换了），
/// 判等靠长度 + 全量散列。
String qtSceneLaneIdentity(List<BasicListItem> lane) {
  if (lane.isEmpty) {
    return '-';
  }
  return '${lane.length}:${_qtSceneLaneHash(lane)}:${lane.first.key}:${lane.last.key}';
}

/// 场景的身份签名：决定 Qt 侧"这一份交互上下文"是否还是同一个。
///
/// 只放**目录/集合身份**（页面、目录、专辑、列、搜索词、每列完整有序身份），不放滚动
/// 位置、不放 cells 窗口、不放播放/音频状态：拖动/惯性/切歌本身就是合法变化，每帧换代次
/// 会把它们全判成旧事件，惯性就被自己的代次切换掐死了。
String qtSceneIdentitySignature(BasicViewState state) {
  final StringBuffer buffer = StringBuffer()
    ..write(state.phase.name)
    ..write('|')
    ..write(state.selectedLane)
    ..write('|')
    ..write(state.query.trim())
    ..write('|')
    ..write(state.directory?.id ?? '')
    ..write('|')
    ..write(state.album?.id ?? '');
  for (final List<BasicListItem> lane in state.laneItems) {
    buffer
      ..write('|')
      ..write(qtSceneLaneIdentity(lane));
  }
  return buffer.toString();
}

/// 交互代次的前进规则：0（还没登记）→ 1，之后每次 +1。
///
/// 提成纯函数是为了让"只在集合身份变化时才换代"这条规则可以被测试直接钉住：视图状态
/// 只在 [_identitySignature] 变化时调用它，拖动/惯性/播放状态变化不调用。
int qtSceneNextContext(int current) => current == 0 ? 1 : current + 1;

/// 增量版身份签名：按「列表实例」缓存每一列的身份，避免拖动中每帧重扫整库。
///
/// 为什么 `identical()` 缓存是有效的：集合没变时 controller 会**复用同一份**
/// `List<List<BasicListItem>>`（lib/basic/siren_controller.dart `_laneItemTable()` 按
/// [曲库代际, 检索词, 目录, 页面, 专辑, 喜欢数, 歌单数, 本地集合] 缓存整张表，命中时返回
/// 的是同一批 List 实例，且这些 List 构建后再也不会被就地修改）。所以"实例没变"就是
/// "这一列的完整有序内容没变"。
///
/// 与 [qtSceneIdentitySignature] 必须给出**完全相同**的签名（同一份判据的快速实现）。
class QtSceneIdentityTracker {
  final List<List<BasicListItem>?> _lanes = <List<BasicListItem>?>[];
  final List<String> _identities = <String>[];

  /// 这一列的身份（命中缓存时零扫描）。
  String identityOf(int lane, List<BasicListItem> items) {
    while (_lanes.length <= lane) {
      _lanes.add(null);
      _identities.add('');
    }
    if (identical(_lanes[lane], items)) {
      return _identities[lane];
    }
    final String identity = qtSceneLaneIdentity(items);
    _lanes[lane] = items;
    _identities[lane] = identity;
    return identity;
  }

  String signature(BasicViewState state) {
    final StringBuffer buffer = StringBuffer()
      ..write(state.phase.name)
      ..write('|')
      ..write(state.selectedLane)
      ..write('|')
      ..write(state.query.trim())
      ..write('|')
      ..write(state.directory?.id ?? '')
      ..write('|')
      ..write(state.album?.id ?? '');
    final List<List<BasicListItem>> lanes = state.laneItems;
    for (int lane = 0; lane < lanes.length; lane++) {
      buffer
        ..write('|')
        ..write(identityOf(lane, lanes[lane]));
    }
    return buffer.toString();
  }

  /// 视图销毁时调用：缓存归零，避免把上一份列表实例的结论带进下一轮。
  void reset() {
    _lanes.clear();
    _identities.clear();
  }
}


/// 原生渲染参数：设置面板里那些**真的影响渲染**的项，随场景快照一起去 Qt。
///
/// 这里只是同一个真值的投影：Dart 侧的唯一真值是 [BasicSettingsRuntime] 的持久化值，
/// Qt 侧不保存第二份。`restart` 组（图形后端/垂直同步/渲染分辨率/抗锯齿）在 Android
/// 上由进程启动时的 Qt main.cpp 读取同一套 `panel/*` 偏好（Host.cpp:1075-1089），
/// 所以这里下发的意义是"写进 Qt 的偏好"，真生效在下次启动；`disc`/`mask` 是逐帧读的，
/// 下发即生效（Engine.cpp:1296 / NativeHudController.cpp:50-52）。
class BasicSceneSettings {
  const BasicSceneSettings({
    this.discRotation = false,
    this.archiveMaskStrength = 55,
    this.vsync = true,
    this.renderScale = 75,
    this.graphicsBackend = '',
    this.aaMode = 'off',
    this.aaScale = 125,
    this.msaa = 0,
    this.supersample = 1,
    this.viewerSeq = 0,
    this.viewerAction = '',
    this.bootPhase = false,
  });

  final bool discRotation;
  final int archiveMaskStrength;
  final bool vsync;
  final int renderScale;
  final String graphicsBackend;
  final String aaMode;
  final int aaScale;
  final int msaa;
  final int supersample;

  /// 封面查看器（Qt `NativeViewer`）的单次命令序号。
  ///
  /// Flutter→Qt 只有 `state`/`pointer`/`wheel` 三个方法
  /// （android/.../qt/QtSceneChannel.kt:123-170），没有任何"动作"通道，所以打开/关闭
  /// 查看器也只能贴着场景快照下发。`seq` 单调递增：同一份快照被重复应用
  /// （EmbeddedSceneHost 的 reapplyPendingState / 首帧 replay）时 Qt 只执行一次。
  ///
  /// 这条命令和渲染参数不同，它**不是**偏好，Qt 侧不落盘、不保存第二份状态；
  /// 查看器自己的状态仍在 Qt 的 NativeViewer 里（与独立 Qt 版同一条链）。
  final int viewerSeq;

  /// `''`（无命令）| `open` | `close` | `clear` | `frosted` | `reset` | `cover-front`。
  final String viewerAction;

  /// 初始化页面（boot 相位）是否在场：为 true 时快照的 `mode` 强制为 "boot"。
  ///
  /// Qt 独立版进入 boot 时 `NativeScene::setMode("boot")`（NativeScene.cpp:194-227），
  /// 由场景自己按 `m_bootStart = m_clock - 1.76` 的时间轴画 3D 引导视觉
  /// （NativeSceneFrame.cpp:18-21，35s 硬闸门切 detail）。内嵌时相位由 Flutter 决定，
  /// 所以这个开关必须随快照过去，否则 3D 层会在初始化页面底下画资料库。
  final bool bootPhase;

  /// 有查看器命令要随快照下发（见 [viewerSeq]）。
  bool get hasViewerCommand => viewerAction.isNotEmpty;

  /// 快照里的 `coverViewer` 字段；没有命令时返回 null。
  Map<String, Object?>? get viewerCommandJson => hasViewerCommand
      ? <String, Object?>{'seq': viewerSeq, 'action': viewerAction}
      : null;

  static const BasicSceneSettings fallback = BasicSceneSettings();

  Map<String, Object?> toJson() => <String, Object?>{
        'disc': discRotation,
        'mask': archiveMaskStrength,
        'vsync': vsync ? 'on' : 'off',
        'renderScale': renderScale,
        'backend': graphicsBackend,
        'aa': aaMode,
        'aaScale': aaScale,
        'msaa': msaa,
        'supersample': supersample,
      };

  @override
  bool operator ==(Object other) =>
      other is BasicSceneSettings &&
      other.discRotation == discRotation &&
      other.archiveMaskStrength == archiveMaskStrength &&
      other.vsync == vsync &&
      other.renderScale == renderScale &&
      other.graphicsBackend == graphicsBackend &&
      other.aaMode == aaMode &&
      other.aaScale == aaScale &&
      other.msaa == msaa &&
      other.supersample == supersample &&
      other.viewerSeq == viewerSeq &&
      other.viewerAction == viewerAction &&
      other.bootPhase == bootPhase;

  @override
  int get hashCode => Object.hash(discRotation, archiveMaskStrength, vsync,
      renderScale, graphicsBackend, aaMode, aaScale, msaa, supersample,
      viewerSeq, viewerAction, bootPhase);
}

String qtSceneStateSnapshot(
  BasicViewState state, {
  BasicSceneSettings? settings,
  int? viewId,
  int contextGeneration = 0,
}) {
  final SirenSong? song = state.song;
  final int index = qtSceneSelectedIndexOf(state);
  // `current` 是**选中身份**（不是 playingTrack）：Qt 侧 render-only 没有曲库，封面只能
  // 由这里投影过去。cover 是原始 URL：Qt 的 Host::image() 只是 cache 查询，真正下载走
  // Host::loadCover(url, cb)，cb 拿到的是加过 `param=NyN` 的**返回** cache key。
  // 没有选中就整块省略 → Qt 清掉旧封面（不能留着上一首的图）。
  final Map<String, Object?>? current =
      (song == null || song.key.isEmpty)
          ? null
          : <String, Object?>{
              'kind': 'song',
              'id': song.id,
              'key': song.key,
              'cover': qtSceneCoverOf(state, song),
              'title': song.title,
              'artist': song.artist,
              // 播放真值：内嵌（render-only）时 Qt 的 NativeApplication 没有曲库也没有
              // 自己的播放器（NativeApplication.cpp:166-177 只投影 current/cover），
              // 唱片旋转因此不能读 Qt 播放器（Engine.cpp:1529-1548 读 player.state）。
              // 这里把唯一播放器（Flutter 侧）的 playing 投影过去，Qt 只读不算。
              'playing': state.playing,
            };
  final Map<String, Object?> payload = <String, Object?>{
    'v': 4,
    // producer/input 的 origin：平台视图 id + 稳定的交互上下文代次。
    // Native 侧（EmbeddedSceneHost）把它们记成"最后应用的那一份"，之后所有排队中的
    // pointer/wheel/scroll/action 都带着自己的 origin 回来对——对不上就丢，
    // 而不是把旧视图（或同视图的旧目录）的事件贴到当前场景上。
    if (viewId != null) 'view': viewId,
    'ctx': contextGeneration,
    'dark': state.dark,
    // boot 相位由宿主的外壳状态决定（Flutter 是唯一相位真值）：初始化页面在场时
    // 场景走 Qt 自己的 boot 时间轴，和独立版一致。
    'mode': settings?.bootPhase == true ? 'boot' : qtSceneModeOf(state),
    'index': index,
    'count': state.songs.length,
    // 连续窗口位置（条目，小数 = 两项之间）与所属列：Qt 只**投影**它，
    // 不把它当第二份真值。拖动中途也会变，所以 3D 场景在手指还没松时就跟着滚。
    'pos': state.listPosition ?? 0,
    'lane': state.selectedLane,
    'cells': qtSceneCellsOf(state),
    if (settings != null) 'settings': settings.toJson(),
    // 查看器命令（见 BasicSceneSettings.viewerSeq）：只在有命令时出现，Qt 侧按 seq
    // 去重后执行一次，不会因为快照重复下发而二次打开/关闭。
    if (settings != null && settings.hasViewerCommand)
      'coverViewer': settings.viewerCommandJson,
    if (current != null) 'current': current,
    if (song != null && song.key.isNotEmpty) 'key': song.key,
  };
  return jsonEncode(payload);
}

/// 40 格语义槽位（5 列 × 8 物理行）。
///
/// Qt 侧已经有真实的 `m_columns` / `physicalSlots` 几何与物理选中（NativeScene.cpp
/// 的 cell{ lane, 12+row }），这里**不重造几何**，只把每个物理格的业务身份
/// （kind + id）与 Flutter 唯一的列表真值对起来，让原生能回传正确 identity 而不是
/// `logical%40` 之类的位置当身份。
///
/// 有界：最多 5×8 条；空列/越界不产生条目（空槽就是空槽，不造占位）。
/// 行键沿用 Qt 的 wrap 语义（src/MusicLibrary.cpp:646-667）：`index = offset + row`
/// 允许负数/超过末尾，取模回列表内——负数窗口起点是 Qt 的真实行为，不在这里夹平。
///
/// 带真实 metadata：`c`/`a`/`b` 是本格源条目的封面 URL/艺人/专辑，取自
/// [BasicListItem]（由 basicLibraryItems 从 SirenSong/SirenAlbum 填），不是
/// `current`（选中身份）的复制。Qt 侧 Engine::projectEmbeddedCells 按
/// `siren:<kind>:<id>` 去重、限流、准入纹理；空封面走 honest placeholder，
/// 绝不把选中那张的图贴到所有格上。
/// 当前列的窗口基址（物理行 12 对应的条目行号）。
///
/// 唯一真值是连续的 `listPosition`：窗口基址 = `round(pos) ~/ 8 * 8`，于是
/// `round(pos) % 8` 就是选中条目所在的物理槽位（0..7）。`laneOffsets` 只是 HUD
/// 的松手记忆（8 的倍数），**不能**拿来做连续拖动的基准——那样 pos 为小数时
/// 反向折行会整体偏移（审查 MUST-5）。非当前列没有连续位置，退回记忆值。
int qtSceneWindowBase(BasicViewState state, int lane) {
  final List<int> offsets = state.laneOffsets;
  final int memory = lane >= 0 && lane < offsets.length ? offsets[lane] : 0;
  if (lane != state.selectedLane) {
    return memory;
  }
  final double? pos = state.listPosition;
  if (pos == null || !pos.isFinite) {
    return memory;
  }
  return (pos.round() ~/ qtScenePhysicalRows) * qtScenePhysicalRows;
}

List<Map<String, Object?>> qtSceneCellsOf(BasicViewState state) {
  final List<List<BasicListItem>> table = state.laneItems;
  if (table.isEmpty) {
    return const <Map<String, Object?>>[];
  }
  final List<Map<String, Object?>> cells = <Map<String, Object?>>[];
  for (int lane = 0; lane < qtSceneLaneCount && lane < table.length; lane++) {
    final List<BasicListItem> items = table[lane];
    if (items.isEmpty) {
      continue;
    }
    final int offset = qtSceneWindowBase(state, lane);
    for (int row = 0; row < qtScenePhysicalRows; row++) {
      final int raw = offset + row;
      final int index = ((raw % items.length) + items.length) % items.length;
      final BasicListItem item = items[index];
      final String cover = qtSceneCellCoverOf(state, item);
      cells.add(<String, Object?>{
        'l': lane,
        // 绝对行域：`12 + 轨道条目` 的行键偏移（= 窗口基址 + 窗口内行）。
        // 必须与原生 pick 的绝对场景行同一个域，否则 pos≥8 时身份查表必然 miss，
        // 退化分支还会把行号放大一个基址（审查 MUST-1'/MUST-5'）。
        'r': offset + row,
        'k': item.kind,
        'i': item.id,
        't': item.title,
        // 真实 metadata：只在本格自己的源条目有值时才带键（省字节，也避免把
        // 空串当成"有一张空图"）。封面仍是 URL，抓取/重试/纹理准入全在 Qt 侧。
        if (cover.isNotEmpty) 'c': cover,
        if (item.artist.isNotEmpty) 'a': item.artist,
        if (item.album.isNotEmpty) 'b': item.album,
      });
    }
  }
  return cells;
}

/// Qt 物理几何：5 列 × 8 物理行（NativeScene 的 m_columns / cell.row = 12+row）。
const int qtSceneLaneCount = 5;
const int qtScenePhysicalRows = 8;

/// 原生 → Dart 的归档滚动回执前缀（走既有的 `action` 字符串通道）。
///
/// 格式 `archive-scroll:<start|move|commit>:<deltaRows>`；deltaRows 是**条目**增量
/// （Qt 的拖拽/滚轮位移按行折算，见 NativeScene 的滚动出口）。分三类是为了让
/// Flutter 记住序列起点、并在松手时才落行选中——与 Qt 的 observe/select 同构。
const String qtSceneScrollPrefix = 'archive-scroll:';

/// 一条原生归档滚动回执。
class QtSceneScrollEvent {
  const QtSceneScrollEvent({
    required this.deltaRows,
    this.started = false,
    this.committed = false,
  });

  /// 相对序列起点的条目增量（可为小数、可为负）。
  final double deltaRows;

  /// 这条是不是一次拖拽/滚轮的起点（用来记 origin）。
  final bool started;

  /// 松手/滚轮结束：是否落行选中。
  final bool committed;

  /// 解析原生 action 字符串；不是滚动回执返回 null。
  static QtSceneScrollEvent? parse(String action) {
    if (!action.startsWith(qtSceneScrollPrefix)) {
      return null;
    }
    final List<String> parts = action
        .substring(qtSceneScrollPrefix.length)
        .split(':');
    if (parts.length != 2) {
      return null;
    }
    final double delta = double.tryParse(parts[1]) ?? 0;
    switch (parts[0]) {
      case 'start':
        return QtSceneScrollEvent(deltaRows: delta, started: true);
      case 'commit':
        return QtSceneScrollEvent(deltaRows: delta, committed: true);
      case 'move':
        return QtSceneScrollEvent(deltaRows: delta);
      default:
        return null;
    }
  }
}

/// 原生回传的**几何格**（Qt 的 cell{lane,row}，row 是 12..19 的物理行）。
///
/// 为什么回传格子而不是列表下标：几何与物理槽位归 Qt，条目身份归 Flutter 唯一真值。
/// Flutter 收到 (lane,row) 后用自己的 [_laneItems]/offsets 折成行号——这正是
/// "native 用真实几何 ID 绑定、回传正确 identity"的那一半，不需要 Qt 认识 Siren 曲目。
class QtSceneCellRef {
  const QtSceneCellRef(this.lane, this.row, {this.kind, this.id});

  final int lane;
  final int row;

  /// 40 格语义表里的业务身份（原生从 `cells` 里查出来一起回传）。
  ///
  /// 只带回几何是不够的：窗口一动，同一个物理行就换了条目；身份才是"回传正确
  /// identity"的部分。原生不带身份时（旧格式）这里为 null，退化成纯几何折行。
  final String? kind;
  final String? id;

  static const String prefix = 'archive-select:';

  /// 两种线上格式：
  /// - `archive-select:<lane>:<row>`（只有几何）
  /// - `archive-select:<lane>|<row>|<kind>|<id>`（几何 + 身份；id 里允许有冒号）
  static QtSceneCellRef? parse(String action) {
    if (!action.startsWith(prefix)) {
      return null;
    }
    final String body = action.substring(prefix.length);
    if (body.contains('|')) {
      final List<String> parts = body.split('|');
      if (parts.length < 4) {
        return null;
      }
      final int? lane = int.tryParse(parts[0]);
      final int? row = int.tryParse(parts[1]);
      if (lane == null || row == null) {
        return null;
      }
      final String kind = parts[2];
      final String id = parts.sublist(3).join('|');
      return QtSceneCellRef(lane, row,
          kind: kind.isEmpty ? null : kind, id: id.isEmpty ? null : id);
    }
    final List<String> parts = body.split(':');
    if (parts.length != 2) {
      return null;
    }
    final int? lane = int.tryParse(parts[0]);
    final int? row = int.tryParse(parts[1]);
    if (lane == null || row == null) {
      return null;
    }
    return QtSceneCellRef(lane, row);
  }
}

/// 物理行 -> 当前列表行（Qt 的 wrap 语义：`index = offsets[lane] + row`，负数/越界取模）。
///
/// 只对**当前列**成立：3D 手势不换所属列，换列必须走 HUD 的显式 ←/→。别的列返回 null，
/// 调用方就知道"这一格不是当前窗口里的条目"，不去猜。
int? qtSceneRowOfCell(BasicViewState state, QtSceneCellRef cell) {
  if (cell.lane != state.selectedLane) {
    return null;
  }
  final List<List<BasicListItem>> table = state.laneItems;
  if (cell.lane < 0 || cell.lane >= table.length) {
    return null;
  }
  final List<BasicListItem> items = table[cell.lane];
  if (items.isEmpty) {
    return null;
  }
  // 1) 身份优先：原生带回来的 (kind,id) 直接在这一列里找出真实行。窗口移动后
  //    同一个物理行对应的条目会变，只有身份永远指向同一条。
  final String? kind = cell.kind;
  final String? id = cell.id;
  if (kind != null && id != null && id.isNotEmpty) {
    final int index = items.indexWhere((BasicListItem item) => item.kind == kind && item.id == id);
    if (index >= 0) {
      return index;
    }
  }
  // 2) 退化到几何：`cell.row` 是**绝对场景行**（原生 pick 返回 12+轨道条目），
  //    减去 12 就是条目行本身，不能再叠加窗口基址（审查 MUST-1' 反例：pos=87 时
  //    叠加会得到 167）。
  final int raw = cell.row - 12;
  return ((raw % items.length) + items.length) % items.length;
}

/// Qt 3D 滚动回执的默认接收面。
///
/// [QtSceneView] 的 `onScroll` 参数优先；HUD 里的场景视图没有传这个参数时（它的
/// 构造点在 HUD 内部），回执落到这里。BasicApp 在 initState 里把 controller 的
/// 连续窗口写入挂上来——这样"3D 拖动/滚轮 → 列表/ruler/换列"不依赖 HUD 接线。
/// 详情页唱片转到阈值以外的回执：`archive-step:next` / `archive-step:prev`。
///
/// 原生只报"用户把唱片转到底了"这个手势，换到哪一张由这里的列表真值决定（原始 Qt
/// 的"转到底换一张"行为）。+-1 表示方向，null 表示不是这类回执。
const String qtSceneStepPrefix = 'archive-step:';

int? qtSceneStepOf(String action) {
  if (!action.startsWith(qtSceneStepPrefix)) {
    return null;
  }
  final String body = action.substring(qtSceneStepPrefix.length);
  if (body == 'next') {
    return 1;
  }
  if (body == 'prev') {
    return -1;
  }
  return null;
}

class QtSceneScrollRouter {
  QtSceneScrollRouter._();

  static final QtSceneScrollRouter instance = QtSceneScrollRouter._();

  ValueChanged<QtSceneScrollEvent>? handler;

  void dispatch(QtSceneScrollEvent event) => handler?.call(event);
}

/// 原生动作的分发表：platform view id → 回调。
///
/// 通道是进程级的，视图是按页面出现的，所以分发必须按 viewId 走，不能假设只有一个
/// 场景视图同时活着（横竖屏切换、退出重进都可能先后存在两个）。
/// 原生 → Dart 的动作接收面（`action` 方法调用）。
///
/// 生产者是 `Qt/src/EmbeddedSceneHost.cpp` 的 pointerup 分支：**只有一次点选**
/// （位移小于阈值）才会发 `archive-select:<lane>|<row>|<kind>|<id>`，拖动松手不发——
/// 否则列表会先跳到手指处那首歌再被惯性落点拉回（用户实测"原地跳动一次"，也是
/// P0#1 禁止的双消费）。滚动回执 `archive-scroll:<phase>:<delta>` 走另一条分流。
class QtSceneActions {
  QtSceneActions._();

  static final Map<int, ValueChanged<String>> _callbacks =
      <int, ValueChanged<String>>{};

  /// 每个视图当前生效的交互上下文代次（0 = 未登记，此时该视图的动作一律丢弃）。
  ///
  /// origin 门禁的另一半：原生只把**它记下的 origin** 写回动作里；如果这个视图像素
  /// 已经换到另一个目录（ctx 递增），旧 ctx 的迟到动作就不能再驱动列表——否则
  /// "同 view 换目录"会把上一页的选中/滚动贴到新页面上。
  ///
  /// 三处 fail-closed（原生侧 Kotlin 已先拦一遍，这里是第二道）：未登记（unbound）、
  /// 动作没带 ctx、ctx 与登记值不等——都不交给页面。宁可丢一个动作，也不用"当前代次"
  /// 给迟到动作补标签。
  static final Map<int, int> _contexts = <int, int>{};
  static MethodChannel? _channel;

  /// 安装通道处理器（幂等）。测试里用 [installForTest] 换成 mock 通道。
  static void install({
    MethodChannel channel = const MethodChannel(qtSceneChannelName),
  }) {
    if (_channel != null && _channel!.name == channel.name) {
      return;
    }
    _channel = channel;
    channel.setMethodCallHandler(handleNativeCall);
  }

  @visibleForTesting
  static void resetForTest() {
    _callbacks.clear();
    _contexts.clear();
    _channel = null;
  }

  static void register(int viewId, ValueChanged<String>? callback) {
    if (callback == null) {
      _callbacks.remove(viewId);
      _contexts.remove(viewId);
      return;
    }
    _callbacks[viewId] = callback;
  }

  /// 视图的交互上下文代次变了（同 view 换目录/换列/换所属）：
  /// 记下新代次，旧代次的动作从此被丢弃。
  static void setContext(int viewId, int contextGeneration) {
    if (!_callbacks.containsKey(viewId)) {
      return;
    }
    _contexts[viewId] = contextGeneration;
  }

  static void unregister(int viewId) {
    _callbacks.remove(viewId);
    _contexts.remove(viewId);
  }

  @visibleForTesting
  static Future<Object?> handleNativeCall(MethodCall call) async {
    switch (call.method) {
      case 'action':
        final Object? raw = call.arguments;
        if (raw is! Map) {
          return null;
        }
        final Object? id = raw['viewId'];
        final Object? ctx = raw['ctx'];
        final Object? action = raw['action'];
        if (id is int && action is String) {
          if (id < 0) {
            debugPrint('RHINE_DART scene_action_dropped_no_origin action=$action');
            return null;
          }
          final int known = _contexts[id] ?? 0;
          if (known == 0) {
            // 视图还没登记代次（或已注销）：没有可比对的归属，直接丢。
            debugPrint('RHINE_DART scene_action_dropped_unbound view=$id action=$action');
            return null;
          }
          if (ctx is! int || ctx != known) {
            // 迟到的旧上下文：明确丢弃，不交给页面。
            debugPrint('RHINE_DART scene_action_dropped view=$id ctx=$ctx known=$known');
            return null;
          }
          _callbacks[id]?.call(action);
        }
        return null;
      default:
        return null;
    }
  }
}

/// Dart → 原生：把快照推给 Qt 场景。
class QtSceneStateSender {
  QtSceneStateSender({
    MethodChannel channel = const MethodChannel(qtSceneChannelName),
  }) : _channel = channel;

  final MethodChannel _channel;

  /// 同一份快照不重复发（Qt 侧解析+重建也是成本）。返回是否真的发出去了。
  ///
  /// [contextGeneration] 与快照里的 `ctx` 是同一个值，单独传一份是给 Kotlin 侧做
  /// 每视图登记/门禁用——原生不该为了拿 origin 去解析一遍业务 JSON。
  ///
  /// 去重键必须**含代次**：只用快照字符串做键时，"同一份快照、只换了代次"会被当成重复
  /// 吞掉，Kotlin 的 `contexts[viewId]` 永远学不到新代次，该视图之后的 pointer/wheel/
  /// action 全部按 fail-closed 丢掉——静默、无日志、也再无恢复路径（直到快照内容本身
  /// 又变化一次）。快照里通常自带 `ctx`，但 sender 是公开 API，不能依赖调用点自觉。
  Future<bool> push(int viewId, String snapshot, {int contextGeneration = 0}) async {
    final String key = '$contextGeneration\u0000$snapshot';
    if (_sent[viewId] == key) {
      return false;
    }
    _sent[viewId] = key;
    try {
      final Object? accepted = await _channel.invokeMethod<Object?>(
        'state',
        <String, Object?>{
          'viewId': viewId,
          'ctx': contextGeneration,
          'json': snapshot,
        },
      );
      if (accepted == false) {
        // 原生侧没受理（Qt 主线程还没建好/视图已解绑）：不能留着去重记录，否则同一份
        // 快照再也不会重发，场景会一直停在默认 mode / 无封面。
        _sent.remove(viewId);
        return false;
      }
      return true;
    } on MissingPluginException {
      // 非 Android / 通道还没装（测试或宿主未注册）：不影响首帧，下一次状态变化再试。
      _sent.remove(viewId);
      return false;
    } on PlatformException catch (error, stack) {
      _sent.remove(viewId);
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stack,
          library: 'qt_scene_view',
          context: ErrorDescription('while pushing Qt scene state'),
        ),
      );
      return false;
    }
  }

  void forget(int viewId) => _sent.remove(viewId);

  /// 每个视图上一次发出的去重键（代次 + '\u0000' + 快照），不是裸快照。
  final Map<int, String> _sent = <int, String>{};
}

/// Dart → 原生的**原始指针**转发。
///
/// 为什么需要它：hybrid composition 下 Android 本来会把触摸直接派发给 QtView，
/// 但当 Flutter 的 HUD 层叠在场景之上时，引擎会插入一层 PlatformOverlayView，
/// 触摸到不了原生子树（实测 FrameLayout.dispatchTouchEvent 一次都不进）。于是
/// 由 Flutter 把**原始** down/move/up/cancel 按同一套舞台换算转给 Qt 的
/// Engine::pointer——谁被拖、拖多远仍然由 Qt 的 NativeSceneInput 决定。
///
/// 这不是"Flutter 另造相机"：这里不做任何手势语义判定，只搬运坐标；判定拖谁、拖多远、
/// 是否旋转仍然全在 Qt 的 NativeSceneInput 里。
///
/// 关于双消费：Qt 的 Embedded.qml 里另有一层 inputLayer（原生触摸直达时用），与这里
/// **没有**仲裁机制——目前之所以只有一条路在跑，是因为 hybrid composition 下原生派发
/// 到不了 Qt 子树（实测 FrameLayout.dispatchTouchEvent 一次都不进）。若将来原生恢复可达，
/// 必须加 owner 协商（例如快照里带 pointerOwner，QML 据此把 inputLayer 关掉），不能两条
/// 同时转发。
class QtScenePointerSender {
  QtScenePointerSender({
    MethodChannel channel = const MethodChannel(qtSceneChannelName),
  }) : _channel = channel;

  final MethodChannel _channel;

  /// 当前视图的交互上下文代次。桥在 attach/换目录时更新；每个事件显式带上它。
  int currentContext = 0;

  /// [x]/[y] 是**舞台单位**（与 Overlay.qml 的 x / stageScale 同义）。
  ///
  /// [contextGeneration] 跟着每一个事件走完整条队列（Dart → Kotlin → Qt）：Qt 侧把它
  /// 与"最后应用的那一份快照"的 origin 对比，对不上就丢。这样排队的旧 A 视图事件
  /// 不会在 B 已经接手后落到 B 的场景上。
  Future<void> pointer(int viewId, String type, double x, double y,
      {int? contextGeneration}) async {
    try {
      await _channel.invokeMethod<void>('pointer', <String, Object?>{
        'viewId': viewId,
        'ctx': contextGeneration ?? currentContext,
        'type': type,
        'x': x,
        'y': y,
      });
    } on MissingPluginException {
      // 通道没装（非 Android / 测试）：静默，场景照常渲染。
    } on PlatformException {
      // 原生侧忙或视图已销毁：丢弃这一次，不打断手势序列的其余事件。
    }
  }

  Future<void> wheel(int viewId, double x, double y, double delta,
      {int? contextGeneration}) async {
    try {
      await _channel.invokeMethod<void>('wheel', <String, Object?>{
        'viewId': viewId,
        'ctx': contextGeneration ?? currentContext,
        'x': x,
        'y': y,
        'delta': delta,
      });
    } on MissingPluginException {
      // 同上。
    } on PlatformException {
      // 同上。
    }
  }
}

/// 原始指针搬运桥（为什么需要搬运见 [QtScenePointerSender]）。
///
/// 关键事实：HUD 的点击层在 Stack 里位于场景**之上**，Flutter 的命中测试
/// 到它即停止（stack 只命中第一个命中的子节点），所以拖动事件只能从那一层
/// 取出（[QtSceneRawPointerLayer]），场景自己再挂一个 Listener 是永远收不到的。
/// 桥因此是**单例**：两种挂法共用一个指针状态机，同一事件不会被转发两次。
class QtScenePointerBridge {
  QtScenePointerBridge._();

  static final QtScenePointerBridge instance = QtScenePointerBridge._();

  final QtScenePointerSender _sender = QtScenePointerSender();
  /// 去重键必须带事件类型：同一次扫描里 down/up 可能共享 timeStamp 且坐标相同
  /// （合成事件、重采样），只按 timeStamp+位置去重会把真正的 up 吞掉，Qt 侧就永远
  /// 停在下压状态。键 = '<type>|timeStamp'，值是位置。
  final Map<int, String> _lastKey = <int, String>{};
  final Map<int, Offset> _lastPosition = <int, Offset>{};
  /// 真正给 Qt 发过 pointerdown 的指针。只有它们的 move/up 才会转发：
  /// 双指落下时 Qt 收到的是 pointercancel，剩下的那根手指没有被 Qt 认领过，
  /// 它的 move 就是"幽灵拖动"（设备实测：缩放后松一根手指，归档跟着手指跑）。
  final Set<int> _forwarded = <int>{};
  int? _viewId;

  /// 场景视图创建后调用（同一时刻只服务一个场景视图）。
  ///
  /// 重建视图时会先 attach 新的 viewId：旧视图上已判定给 Qt 的指针不会再有 up，
  /// 必须在这里显式 pointercancel 掉再重绑，否则新视图第一帧就可能带着上一视图的
  /// 下压状态（旧实现直接覆盖 _viewId，等于把那些指针静默丢掉）。
  void attach(int viewId, {int contextGeneration = 0}) {
    if (_viewId != null && _viewId != viewId) {
      releasePointers(_forwarded);
    }
    _viewId = viewId;
    _sender.currentContext = contextGeneration;
    _reset();
  }

  /// 同 view 的目录/所属变了：后续事件带新代次，Qt 侧据此拒掉排队中的旧事件。
  void setContext(int viewId, int contextGeneration) {
    if (_viewId == viewId) {
      _sender.currentContext = contextGeneration;
    }
  }

  /// 释放这些指针：给 Qt 发过 pointerdown 的补一个 pointercancel（不留悬挂下压），
  /// 然后清掉它们的去重/转发状态。只动传进来的指针，不影响别的视图。
  void releasePointers(Iterable<int> pointers) {
    final int? viewId = _viewId;
    final List<int> released = pointers.toList(growable: false);
    for (final int pointer in released) {
      final Offset? position = _lastPosition[pointer];
      if (viewId != null && _forwarded.contains(pointer) && position != null) {
        _sender.pointer(viewId, 'pointercancel', position.dx, position.dy);
      }
      _forwarded.remove(pointer);
      _lastKey.remove(pointer);
      _lastPosition.remove(pointer);
    }
  }

  /// 测试用：当前绑定的视图 id（生产代码不要读它）。
  int? get viewIdForTest => _viewId;

  /// 测试用：清空指针状态机（生产代码不要调用）。
  void resetForTest() => _reset();

  void detach(int viewId) {
    if (_viewId == viewId) {
      _viewId = null;
      // 代次归零：脱离后任何残留事件带 0，原生侧 acceptsInput 一律丢弃（没有"沿用上一
      // 个视图代次"的窗口）。
      _sender.currentContext = 0;
      _reset();
    }
  }

  void _reset() {
    _pointers.clear();
    _lastKey.clear();
    _lastPosition.clear();
    _forwarded.clear();
    _multi = false;
    _lastCentroid = null;
    _lastDistance = null;
  }

  /// 同一事件被两层同时送来时只转发一次（pointer + timeStamp 去重）。
  /// 视口坐标 → Qt 舞台单位：Qt 用 `scene.resize(width / (height / 1080), 1080)`
  /// 归一（Qt/src/Engine.cpp:841-849），所以只要按场景矩形的高度归一即可，
  /// 与 devicePixelRatio、横竖屏、Transform.scale 都无关。
  Offset _stagePoint(Offset local, Rect sceneRect) {
    if (sceneRect.height <= 0) {
      return Offset.zero;
    }
    final double k = 1080.0 / sceneRect.height;
    return Offset(
      (local.dx - sceneRect.left) * k,
      (local.dy - sceneRect.top) * k,
    );
  }

  bool _claim(PointerEvent event) {
    // 同一指针的同一时刻同一位置**同类型**事件只搬一次；但重采样事件可能共用
    // timeStamp 而坐标不同，那种必须放过（否则快速拖动会丢帧，表现为"拖了一半不跟手"）。
    final String key = '${event.runtimeType}|${event.timeStamp.inMicroseconds}';
    final bool duplicate =
        _lastKey[event.pointer] == key && _lastPosition[event.pointer] == event.position;
    if (duplicate) {
      return false;
    }
    _lastKey[event.pointer] = key;
    _lastPosition[event.pointer] = event.position;
    return true;
  }

  final Map<int, Offset> _pointers = <int, Offset>{};
  bool _multi = false;
  double? _lastDistance;
  Offset? _lastCentroid;

  /// 舞台单位换算：Qt 场景内部固定按 1080 高归一化
  /// （Engine::resize → scene.resize(width / (height / 1080), 1080)），
  void down(PointerDownEvent event, Rect sceneRect) {
    if (_viewId == null || !_claim(event)) {
      return;
    }
    _pointers[event.pointer] = _stagePoint(event.localPosition, sceneRect);
    if (_pointers.length >= 2) {
      if (!_multi) {
        _multi = true;
        // 第二根手指落下：结束可能已开始的单指拖拽/旋转，避免两个手势叠加。
        final int? id = _viewId;
        if (id != null) {
          _sender.pointer(id, 'pointercancel', 0, 0);
        }
        // Qt 那边已经收到 cancel，之前那根手指也不再被认领：它后续的 move 一律不转发。
        _forwarded.clear();
      }
      _lastCentroid = null;
      _lastDistance = null;
      return;
    }
    final int? id = _viewId;
    if (id != null) {
      final Offset stage = _stagePoint(event.localPosition, sceneRect);
      _forwarded.add(event.pointer);
      _sender.pointer(id, 'pointerdown', stage.dx, stage.dy);
    }
  }

  void move(PointerMoveEvent event, Rect sceneRect) {
    if (_viewId == null || !_claim(event)) {
      return;
    }
    _pointers[event.pointer] = _stagePoint(event.localPosition, sceneRect);
    final int? id = _viewId;
    if (id == null) {
      return;
    }
    if (_multi && _pointers.length >= 2) {
      // 双指：质心位移 → pan，间距变化 → wheel（与 Overlay.qml 的 PinchHandler
      // 同一条通路，仍然是 Qt 的 NativeViewer 在做缩放）。
      final Offset a = _pointers.values.elementAt(0);
      final Offset b = _pointers.values.elementAt(1);
      final Offset centroid = (a + b) / 2;
      final double distance = (a - b).distance;
      final Offset? previousCentroid = _lastCentroid;
      final double? previousDistance = _lastDistance;
      _lastCentroid = centroid;
      _lastDistance = distance;
      if (previousCentroid != null) {
        final double dx =
            (centroid.dx - previousCentroid.dx) * 1080.0 / sceneRect.height;
        final double dy =
            (centroid.dy - previousCentroid.dy) * 1080.0 / sceneRect.height;
        if (dx != 0 || dy != 0) {
          _sender.pointer(id, 'pan', dx, dy);
        }
      }
      if (previousDistance != null && previousDistance > 0 && distance > 0) {
        final double delta = math.log(distance / previousDistance) * 350;
        if (delta.abs() > 0.5) {
          final Offset stage = _stagePoint(centroid, sceneRect);
          _sender.wheel(id, stage.dx, stage.dy, delta);
        }
      }
      return;
    }
    if (_pointers.length == 1 && _forwarded.contains(event.pointer)) {
      final Offset stage = _stagePoint(event.localPosition, sceneRect);
      _sender.pointer(id, 'pointermove', stage.dx, stage.dy);
    }
  }

  void up(PointerEvent event, Rect sceneRect) {
    if (_viewId == null || !_claim(event)) {
      return;
    }
    _pointers.remove(event.pointer);
    final bool forwarded = _forwarded.remove(event.pointer);
    _lastKey.remove(event.pointer);
    _lastPosition.remove(event.pointer);
    final int? id = _viewId;
    if (id == null) {
      return;
    }
    if (!forwarded) {
      // 这根手指没被 Qt 认领（双指时的第二根，或 cancel 之后剩下的那根）：
      // 不发 pointerup，否则 Qt 会收到一个没有 down 的 up。
      if (_pointers.isEmpty) {
        _multi = false;
        _lastCentroid = null;
        _lastDistance = null;
      }
      return;
    }
    if (_pointers.isEmpty) {
      final Offset stage = _stagePoint(event.localPosition, sceneRect);
      _sender.pointer(id, 'pointerup', stage.dx, stage.dy);
      _multi = false;
      _lastCentroid = null;
      _lastDistance = null;
      return;
    }
    if (_pointers.length == 1) {
      // 双指变单指：不把剩下的手指当作新的拖拽起点，等它抬起（它不在 _forwarded 里）。
      _multi = false;
      _lastCentroid = null;
      _lastDistance = null;
    }
  }

  /// 系统取消（来电、手势被父级抢走）：Qt 必须收到 pointercancel，不能拿 up 顶替。
  void cancel(PointerCancelEvent event) {
    if (_viewId == null) {
      return;
    }
    final int? id = _viewId;
    if (id != null && _forwarded.contains(event.pointer)) {
      _sender.pointer(id, 'pointercancel', 0, 0);
    }
    _pointers.remove(event.pointer);
    _forwarded.remove(event.pointer);
    _lastKey.remove(event.pointer);
    _lastPosition.remove(event.pointer);
    if (_pointers.isEmpty) {
      _multi = false;
      _lastCentroid = null;
      _lastDistance = null;
    }
  }
}

/// 页面里的 Qt 场景视图。
///
/// 契约（与 HUD 侧约定，不要改参数名/顺序语义）：
/// `QtSceneView({super.key, required BasicViewState state, ValueChanged<String>? onAction,
/// ValueChanged<int>? onCreated})`，HUD 侧调用
/// `QtSceneView(state: state, onAction: onAction)`。
///
/// 分工是明确的：场景状态（材质、模型、相机、归档布局、触摸、动画）由 Qt 的
/// Engine/场景层持有；曲库与播放在 Flutter 这一侧持有，这里只把渲染需要的子集
/// （主题/模式/选中行/身份键）推过去，不推播放指令、也不推第二份曲库。
class QtSceneView extends StatefulWidget {
  const QtSceneView({
    super.key,
    required this.state,
    this.onAction,
    this.onCreated,
    this.onScroll,
    this.settings,
  });

  /// 当前界面状态（只读快照）。选中身份看 state.song，不看播放状态。
  final BasicViewState state;

  /// 渲染参数（设置面板的真实值）。为空时不下发 settings 块，Qt 保持自己的默认值。
  final BasicSceneSettings? settings;

  /// Qt 侧产生的动作（如 'select:12' / 'viewer:open'）。原文透传，不在这里解释词表。
  final ValueChanged<String>? onAction;

  /// platform view id：调用方只用来打日志/排障。
  final ValueChanged<int>? onCreated;

  /// Qt 3D 侧的连续归档滚动（拖动/滚轮）。`action` 通道里的 `archive-scroll:*`
  /// 回执在这里解释成增量，交给 controller 折算成 state.listPosition——3D 拖动
  /// 因此每帧推动列表/ruler，而不是松手才动一次。
  final ValueChanged<QtSceneScrollEvent>? onScroll;

  @override
  State<QtSceneView> createState() => _QtSceneViewState();
}

class _QtSceneViewState extends State<QtSceneView> {
  final QtSceneStateSender _sender = QtSceneStateSender();

  int? _viewId;

  /// 稳定交互上下文代次：只在**目录/集合身份**变化时递增（见
  /// [qtSceneIdentitySignature]），不在拖动/惯性/选中变化时递增。
  int _contextGeneration = 0;
  String? _identitySignature;

  /// 身份的增量计算器：按列表实例缓存每一列的有序指纹，拖动中每帧的那次 `_syncContext`
  /// 不会重扫整库（控制器复用同一份 List 实例时直接命中缓存）。
  final QtSceneIdentityTracker _identity = QtSceneIdentityTracker();

  /// 目录身份变了才换代次，并把新代次登记给动作分发与指针桥。
  void _syncContext() {
    final String signature = _identity.signature(widget.state);
    if (_identitySignature == signature) {
      return;
    }
    _identitySignature = signature;
    _contextGeneration = qtSceneNextContext(_contextGeneration);
    final int? id = _viewId;
    if (id != null) {
      QtSceneActions.setContext(id, _contextGeneration);
      QtScenePointerBridge.instance.setContext(id, _contextGeneration);
    }
  }

  @override
  void initState() {
    super.initState();
    QtSceneActions.install();
  }

  @override
  void didUpdateWidget(QtSceneView oldWidget) {
    super.didUpdateWidget(oldWidget);
    final int? id = _viewId;
    if (id == null) {
      return;
    }
    // 快照只与 state/settings 有关：父级重建但两者都没变时不重复下发
    // （QtSceneStateSender 自己按最后一次字符串去重）。
    if (oldWidget.state != widget.state || oldWidget.settings != widget.settings) {
      _syncContext();
      _sender.push(
        id,
        qtSceneStateSnapshot(
          widget.state,
          settings: widget.settings,
          viewId: id,
          contextGeneration: _contextGeneration,
        ),
        contextGeneration: _contextGeneration,
      );
    }
  }

  @override
  void dispose() {
    final int? id = _viewId;
    if (id != null) {
      QtSceneActions.unregister(id);
      QtScenePointerBridge.instance.detach(id);
      _sender.forget(id);
    }
    // 缓存随视图一起丢弃：下一个视图是新一代次，不该继承上一份列表实例的结论。
    _identity.reset();
    super.dispose();
  }

  /// 原始指针由 [QtScenePointerBridge] 承担：HUD 的点击层在 Stack 里压在场景之上，
  /// Flutter 命中测试到它就停，所以拖动只能从那一层取出（见 bridge 的说明）。
  Widget _withRawPointer(Widget child) {
    // 场景自己不挂搬运层：它在 Stack 里位于 HUD 点击层之下，命中测试永远到不了这里
    // （实测 dispatchTouchEvent 一次都不进）。搬运由 HUD 顶层那层负责 ——
    // 见 [QtSceneRawPointerLayer] 与 [QtScenePointerBridge]。
    return child;
  }

  /// 原生 action 的分流：滚动回执走 [QtSceneView.onScroll]，其余原文透传给
  /// [QtSceneView.onAction]（点选身份 `archive-select:…` 由原生 pointerup 的 tap 分支发出）。
  void _onNativeAction(String action) {
    final QtSceneScrollEvent? scroll = QtSceneScrollEvent.parse(action);
    if (scroll != null) {
      final ValueChanged<QtSceneScrollEvent>? direct = widget.onScroll;
      if (direct != null) {
        direct(scroll);
      } else {
        QtSceneScrollRouter.instance.dispatch(scroll);
      }
      return;
    }
    // 选中身份回执（archive-select:<lane>:<row>）：原生只报它真实拾取到的
    // 物理格，映射成列表行由 Dart 侧当前窗口决定；这里留一行证据日志，
    // 否则"3D 点选没反应"无法区分是没发出来还是被窗口判空丢掉。
    debugPrint('RHINE_DART scene_action $action');
    widget.onAction?.call(action);
  }

  void _onPlatformViewCreated(int id) {
    _viewId = id;
    QtSceneActions.register(id, _onNativeAction);
    // 先算代次再登记/下发：这一份快照是 Qt 侧的"当前 origin"，之后的输入都按它校验。
    _syncContext();
    if (_contextGeneration == 0) {
      // 兜底：正常路径上 `_syncContext` 因为 `_identitySignature` 从 null 变成具体签名而
      // 一定会代入次；这里只防"签名恰好等于 null"这类不可能状态，规则与上面共用同一个
      // 纯函数，避免两处各写一遍 0→1 / +1。
      _contextGeneration = qtSceneNextContext(_contextGeneration);
      _identitySignature = _identity.signature(widget.state);
    }
    QtSceneActions.setContext(id, _contextGeneration);
    QtScenePointerBridge.instance.attach(id, contextGeneration: _contextGeneration);
    // 首个快照必须在视图创建后立刻给：Qt 的归档/唱片/主题都靠它进正确状态，
    // 否则会先按 archive+light 渲染一帧再跳变。
    _sender.push(
      id,
      qtSceneStateSnapshot(
        widget.state,
        settings: widget.settings,
        viewId: id,
        contextGeneration: _contextGeneration,
      ),
      contextGeneration: _contextGeneration,
    );
    widget.onCreated?.call(id);
  }

  @override
  Widget build(BuildContext context) {
    if (!qtScenePlatformSupported) {
      return QtSceneUnsupported(platformLabel: qtScenePlatformLabel());
    }
    // Hybrid composition 的 layoutDirection 在创建 controller 时必须给定，
    // PlatformViewCreationParams 本身不带这个字段（Flutter 3.47），从 Directionality 取。
    final TextDirection layoutDirection =
        Directionality.maybeOf(context) ?? TextDirection.ltr;
    return _withRawPointer(
      PlatformViewLink(
        viewType: qtSceneViewType,
        surfaceFactory:
            (BuildContext context, PlatformViewController controller) {
              return AndroidViewSurface(
                controller: controller as AndroidViewController,
                // opaque：这块矩形归 Qt。HUD 的其它层若需要命中，由 Flutter 自己的
                // gesture detector 处理，两边各自成立、互不改写对方的事件。
                hitTestBehavior: PlatformViewHitTestBehavior.opaque,
                // 空集合 = 触摸原样交给原生视图（Qt），Qt 的 Embedded.qml inputLayer 再把
                // 原始 down/move/up 转给 NativeSceneInput。这里刻意不注册任何识别器：
                // 一旦注册（含 EagerGestureRecognizer），Flutter 的手势竞技场会先赢一次，
                // 与 Qt 抢同一次拖动——那正是"Flutter 另造相机"的另一种写法。
                gestureRecognizers:
                    const <Factory<OneSequenceGestureRecognizer>>{},
              );
            },
        onCreatePlatformView: (PlatformViewCreationParams params) {
          final AndroidViewController controller =
              PlatformViewsService.initExpensiveAndroidView(
                id: params.id,
                viewType: qtSceneViewType,
                layoutDirection: layoutDirection,
                // onFocus 在这里不注册：Qt 视图自己拿 focus（QtView/QtWindow 的舞台与
                // 输入层由 Qt 的 Embedded.qml inputLayer 管理），Flutter 侧不参与焦点仲裁。
              );
          // 必须把 Flutter 自己的创建回调挂上：PlatformViewLink 的
          // _platformViewCreated 只有在 params.onPlatformViewCreated 被调用后才置 true，
          // 而 controller.create() 完成后只会遍历 addOnPlatformViewCreatedListener 注册的回调
          // （flutter/lib/src/services/platform_views.dart 的 create() 尾部）。
          // 少了这一行，widget 永远停在 _PlatformViewPlaceHolder：AndroidViewSurface
          // 从不构建，Qt 视图永远不进合成树（真机只剩 HUD 黑底）。
          controller.addOnPlatformViewCreatedListener(
            params.onPlatformViewCreated,
          );
          // 本类自己的首个快照/动作注册（顺序在 params 回调之后刻意不依赖：
          // 两个监听器都会在 create() 完成时被遍历，_onPlatformViewCreated 只用 id）。
          controller.addOnPlatformViewCreatedListener(_onPlatformViewCreated);
          return controller;
        },
      ),
    );
  }
}

/// 非 Android 的显式占位：说明这里没有场景实现，而不是画一张假的 3D 图。
class QtSceneUnsupported extends StatelessWidget {
  const QtSceneUnsupported({super.key, required this.platformLabel});

  final String platformLabel;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: _sceneBackground,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const Icon(
                Icons.view_in_ar_outlined,
                size: 30,
                color: _sceneMuted,
              ),
              const SizedBox(height: 10),
              const Text(
                '3D 场景预览仅在 Android 可用',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: _sceneText,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                '当前平台：$platformLabel。这里不渲染模型、截图或旋转动画；'
                'Android 上这个矩形里是 Qt 自己的 QQuickView（同进程原生视图）。',
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 11.5,
                  height: 1.4,
                  color: _sceneMuted,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 把任意子树的**原始**指针事件搬给 Qt 场景（包在 HUD 的点击层外面用）。
///
/// [sceneRect] 是 Qt 场景在这层坐标系里的矩形（横屏是逻辑像素、竖屏是舞台单位，
/// 与调用方给 QtSceneView 的那份一致）：换算只按它的高度归一，不猜 dpr。
/// 只搬运 down/move/up/cancel 与双指 pan/缩放；谁被拖、拖多远、何时选中全由 Qt 决定。
class QtSceneRawPointerLayer extends StatefulWidget {
  /// 测试注入点：替换 onPointerCancel 的生产调用（QtScenePointerBridge.cancel）。
  /// 生产恒为 null；它存在的唯一目的是让"取消必须发 pointercancel"这条接线可证伪。
  @visibleForTesting
  static void Function(PointerCancelEvent event)? cancelHook;

  const QtSceneRawPointerLayer({
    super.key,
    required this.sceneRect,
    this.forwardAt,
    required this.child,
  });

  final Rect sceneRect;

  /// 这条手势归谁：返回 true 才转给 Qt，返回 false 表示这一串事件由 HUD 自己处理。
  ///
  /// 这就是"指针归属协商"（pointerOwner）的最小实现：HUD 传入"该点没有 HUD 命中
  /// 目标"，于是点在列表行、按钮、播放条上时不会顺带把 Qt 场景也拖一下
  /// （设备实测问题：点上下按钮，3D 归档跟着动）。
  /// 归属在 pointerdown 时定下来并保持整串手势，不做中途翻转。
  /// null 表示不设判据（所有原始事件都转给 Qt）。
  final bool Function(Offset localPosition)? forwardAt;

  final Widget child;

  @override
  State<QtSceneRawPointerLayer> createState() => _QtSceneRawPointerLayerState();
}

class _QtSceneRawPointerLayerState extends State<QtSceneRawPointerLayer> {
  /// 已判定归 Qt 的指针。只有这些指针的 move/up 才会转发。
  final Set<int> _owned = <int>{};

  @override
  Widget build(BuildContext context) {
    final QtScenePointerBridge bridge = QtScenePointerBridge.instance;
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (PointerDownEvent event) {
        final bool forward =
            widget.forwardAt?.call(event.localPosition) ?? true;
        if (!forward) {
          _owned.remove(event.pointer);
          return;
        }
        _owned.add(event.pointer);
        bridge.down(event, widget.sceneRect);
      },
      onPointerMove: (PointerMoveEvent event) {
        if (!_owned.contains(event.pointer)) {
          return;
        }
        bridge.move(event, widget.sceneRect);
      },
      onPointerUp: (PointerUpEvent event) {
        if (_owned.remove(event.pointer)) {
          bridge.up(event, widget.sceneRect);
        }
      },
      onPointerCancel: (PointerCancelEvent event) {
        if (_owned.remove(event.pointer)) {
          // 可证伪：cancelHook 在测试里替换生产调用；把它改回 bridge.up 会让这条
          // 断言立刻变红（旧实现正是 cancel→pointerup，Qt 侧收不到取消）。
          final void Function(PointerCancelEvent) cancel =
              QtSceneRawPointerLayer.cancelHook ?? bridge.cancel;
          cancel(event);
        }
      },
      child: widget.child,
    );
  }

  @override
  void dispose() {
    // 视图被销毁/重建时，已判定归属的指针不会再有 up：给 Qt 补 pointercancel 再清，
    // 避免跨视图把旧手势带到新视图上。用生产 API（releasePointers）而不是测试用的
    // resetForTest —— 旧实现整体重置状态机，会连别的指针一起去重记录都抹掉。
    if (_owned.isNotEmpty) {
      QtScenePointerBridge.instance.releasePointers(_owned.toList(growable: false));
      _owned.clear();
    }
    super.dispose();
  }
}
