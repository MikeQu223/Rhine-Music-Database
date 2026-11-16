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

/// 选中曲目在当前可见列表里的行号（-1 = 不在列表里/没有选中）。
///
/// 只认 [BasicViewState.song] 这条**选中**身份，不看播放：播放状态是
/// BasicViewState.playing/positionMs，与"用户此刻浏览到哪"是两件事。
int qtSceneSelectedIndexOf(BasicViewState state) {
  final SirenSong? song = state.song;
  if (song == null) {
    return -1;
  }
  return state.songs.indexWhere((SirenSong item) => item.id == song.id);
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

String qtSceneStateSnapshot(BasicViewState state) {
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
            };
  final Map<String, Object?> payload = <String, Object?>{
    'v': 3,
    'dark': state.dark,
    'mode': qtSceneModeOf(state),
    'index': index,
    'count': state.songs.length,
    // 连续窗口位置（条目，小数 = 两项之间）与所属列：Qt 只**投影**它，
    // 不把它当第二份真值。拖动中途也会变，所以 3D 场景在手指还没松时就跟着滚。
    'pos': state.listPosition ?? 0,
    'lane': state.selectedLane,
    'cells': qtSceneCellsOf(state),
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
/// 不带 cover：素材纹理仍由 `current`（单选身份）驱动，逐格下发封面会把 40 个
/// 下载/纹理塞进一次状态推送；卡片面在本版本就是抽取面，不画专辑图。
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
      cells.add(<String, Object?>{
        'l': lane,
        'r': row,
        'k': item.kind,
        'i': item.id,
        't': item.title,
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
  // 2) 退化到几何：基址必须用连续窗口真值（`round(pos) ~/ 8 * 8`），不是 HUD 的
  //    8 倍数记忆值——否则 pos 带小数时点选会整体偏移（审查 MUST-5）。
  final int offset = qtSceneWindowBase(state, cell.lane);
  // 物理行的基址是 12（NativeScene 的 cell.row = 12 + 列内序号）。
  final int raw = offset + (cell.row - 12);
  return ((raw % items.length) + items.length) % items.length;
}

/// Qt 3D 滚动回执的默认接收面。
///
/// [QtSceneView] 的 `onScroll` 参数优先；HUD 里的场景视图没有传这个参数时（它的
/// 构造点在 HUD 内部），回执落到这里。BasicApp 在 initState 里把 controller 的
/// 连续窗口写入挂上来——这样"3D 拖动/滚轮 → 列表/ruler/换列"不依赖 HUD 接线。
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
/// **当前无生产者**：Qt 归档槽位是 40 条占位记录，不带 Siren 身份，用它的 selection
/// 去拼 `music:index:<i>` 会打开别的歌（假映射），所以原生侧已停发。接收面保留，
/// 等权威词表确定后再接。
class QtSceneActions {
  QtSceneActions._();

  static final Map<int, ValueChanged<String>> _callbacks =
      <int, ValueChanged<String>>{};
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
    _channel = null;
  }

  static void register(int viewId, ValueChanged<String>? callback) {
    if (callback == null) {
      _callbacks.remove(viewId);
      return;
    }
    _callbacks[viewId] = callback;
  }

  static void unregister(int viewId) {
    _callbacks.remove(viewId);
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
        final Object? action = raw['action'];
        if (id is int && action is String) {
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
  Future<bool> push(int viewId, String snapshot) async {
    if (_sent[viewId] == snapshot) {
      return false;
    }
    _sent[viewId] = snapshot;
    try {
      final Object? accepted = await _channel.invokeMethod<Object?>(
        'state',
        <String, Object?>{'viewId': viewId, 'json': snapshot},
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

  /// [x]/[y] 是**舞台单位**（与 Overlay.qml 的 x / stageScale 同义）。
  Future<void> pointer(int viewId, String type, double x, double y) async {
    try {
      await _channel.invokeMethod<void>('pointer', <String, Object?>{
        'viewId': viewId,
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

  Future<void> wheel(int viewId, double x, double y, double delta) async {
    try {
      await _channel.invokeMethod<void>('wheel', <String, Object?>{
        'viewId': viewId,
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
  void attach(int viewId) {
    if (_viewId != null && _viewId != viewId) {
      releasePointers(_forwarded);
    }
    _viewId = viewId;
    _reset();
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
  });

  /// 当前界面状态（只读快照）。选中身份看 state.song，不看播放状态。
  final BasicViewState state;

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
    // 快照只与 state 有关：父级重建但状态没变时不重复下发。
    _sender.push(id, qtSceneStateSnapshot(widget.state));
  }

  @override
  void dispose() {
    final int? id = _viewId;
    if (id != null) {
      QtSceneActions.unregister(id);
      QtScenePointerBridge.instance.detach(id);
      _sender.forget(id);
    }
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
  /// [QtSceneView.onAction]（本版本 onAction 仍无生产者，词表未定）。
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
    QtScenePointerBridge.instance.attach(id);
    // 首个快照必须在视图创建后立刻给：Qt 的归档/唱片/主题都靠它进正确状态，
    // 否则会先按 archive+light 渲染一帧再跳变。
    _sender.push(id, qtSceneStateSnapshot(widget.state));
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
