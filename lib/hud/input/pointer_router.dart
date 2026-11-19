/// 指针路由：Qt/qml/Overlay.qml 的事件层与 Qt/src/Engine.cpp:1042-1061（pointer）的 1:1 迁移。
///
/// 坐标契约：PointerEvent.position / delta 是**窗口局部逻辑坐标**（QML 的 mouse.x / mouse.y，
/// 对应 Flutter 的 localPosition，不要用 globalPosition），内部一律经 hitLayer.geometry.toStage
/// 换算成舞台坐标才对外转发。PointerForward.x / y 是舞台坐标
/// （Overlay.qml:98/104/110 的 mouse.x / overlay.stageScale）。
///
/// 按键维度：本层只建模主键（Overlay.qml:90 acceptedButtons: Qt.LeftButton）；shield 是
/// Qt.AllButtons（Overlay.qml:132），但它的判定不依赖按键，宿主可原样送入。
///
/// 端口与返回值的分工：PointerPorts 是唯一副作用出口，PointerOutcome.forwards 是同一事实的
/// 可断言记录。宿主二选一消费（推荐只实现 ports）；两边都消费会重复转发。
///
/// 不可变约束（逐条有 Qt 出处）：
/// - 派发顺序 = 兄弟声明顺序（Qt Quick 把输入交给最上层包含该点的兄弟）：seek/volume 播放控件
///   （Overlay.qml:485-508）→ searchScrollArea（Overlay.qml:222-284）→ 命中 delegate
///   （Overlay.qml:185-220）→ playerBarInputShield（Overlay.qml:123-142）→ inputLayer
///   （Overlay.qml:86-121）。searchScrollArea 声明在 controls 内、Repeater 之后
///   （Overlay.qml:179/185/222），所以在命中之上；这个顺序不能反。
/// - Android 在按下即发命中动作，iOS 在抬起且释放点仍落在同一命中内才发
///   （Overlay.qml:202-212 的 if (!overlay.ios) 与 onClicked）。
/// - move 走 Engine.cpp:1042-1049 的「记录 + 帧末 flush」模型，不是立即转发：坐标与上次记录
///   相同且没有待处理状态时丢弃，否则只记录进待处理态、由 flush() 取出
///   （Engine.cpp:653-659 flushPointer）。非 move 相位在转发自身之前先 flushPointer
///   （Engine.cpp:1050-1052）。宿主必须每帧调用一次 flush()（对应 Engine.cpp:567/750 的帧循环），
///   否则 move 永久滞留在待处理态。记录位初值 (0,0) 且未待处理 => 指向舞台原点的首个 move
///   会被丢弃，这是 Qt 的实际行为，保留。move 相位自身**从不** flush（Qt 的 pointermove 分支
///   只记录），所以 handle(move) 的 forwards 恒为空，同一帧内的多次 move 只在帧末合并成一次。
/// - playerBarInputShield 进入时发一次 pointercancel + pointerleave，坐标固定 0,0
///   （Overlay.qml:134-137，cancel 在前）；一次手势结束后复位，使连续两次按入都能重新取消
///   输入层手势。
/// - 命中 delegate 的 onEntered 与 searchScrollArea 的 onEntered 都发 pointerleave(0,0)
///   （Overlay.qml:201 / :235）。
/// - 桌面 hover 移动：落在 hit / searchScrollArea / shield 上时停在它们的 onEntered（三者都
///   hoverEnabled，却没有转发 onPositionChanged 的路径）；没有被上层消费时落在 inputLayer，
///   它是 hoverEnabled（Overlay.qml:89）且 onPositionChanged 没有 pressed 守卫
///   （Overlay.qml:100-105），因此 hover 移动与 move 同模型：只记录 _lastX/_lastY/_pending，
///   由帧末 flush() 合成一次 pointermove（Engine.cpp:1043-1049、:653-659）。不发 leave/cancel
///   的分支不 flush，纯 hover 不会把上一条待发的 move 提前顶出去。
/// - viewer 捏合激活时 inputLayer 的三条通路一起短路（Overlay.qml:95 按下、:101 移动、:107 抬起），
///   并在激活瞬间发一次 pointercancel(0,0)（Overlay.qml:319-323；注释 :94 说明理由是别让第一根
///   手指的 MouseArea 继续驱动单指旋转）。命中的 delegate 没有这条判断，捏合真正抢走触点靠的是
///   handler 的 grab。
/// - pan 只在捏合激活时转发（Overlay.qml:304-307 的 if (!active) return）；dx==dy==0 跳过；
///   abs(dx) > 0.4 * stageWidth 或 abs(dy) > 0.4 * 逻辑高度时跳过（Overlay.qml:313-314）。
///   dx/dy 来自 scene 像素，而两个阈值分别是舞台单位与窗口单位，这是 Qt 自身的量纲不一致，
///   原样保留、不修正；NaN/Inf 也不过滤，与 Qt 一致（Qt 这里同样没有 finite 检查，NaN 比较
///   恒为 false 因而会被放行）。Qt 在阈值判定之前就把 lastPan 更新成当前质心
///   （Overlay.qml:306-308），所以被拒绝的采样仍会推进锚点；本层只接收增量、不拥有锚点，
///   宿主必须照此实现。
/// - inputLayer 的 onExited / onCanceled（Overlay.qml:112-113）**无条件**转发 leave/cancel(0,0)，
///   与是否持有按下态无关；但两者对**本层状态**的影响不同：onExited 只有一个转发，Qt 既不释放
///   grab、也不把 mouse.pressed 置回 false，随后的 pointermove 仍会走到 onPositionChanged 继续
///   转发；onCanceled 才是按下态的终点。故本层把 leave 与 cancel 拆成两条路径：leave 只 flush +
///   转发并保留 _layer/_pressedHit 与 _dragRouter 的拖拽态，cancel 才复位按下态。
/// - searchScrollArea（Overlay.qml:236-278）：按下即吞掉（state.closing 时更是什么都不记）；
///   位移超过 6（局部单位，即舞台单位）记为拖拽；拖拽期间每次非零位移都转发 wheelInput，
///   像素增量是 mapToItem(inputLayer) 换算出的**窗口像素**（Overlay.qml:252-257），直接当
///   pixelDelta 转发、不再除 stageScale；而 TouchInput.qml:25 转发的是舞台像素。两处不一致，
///   均按原文保留。抬起时若已拖拽或 state.closing 则什么都不做，否则按「含触摸外扩、不含
///   modalOffset」的舞台矩形正向扫描，第一个命中 music:result:/music:expand: 前缀者触发动作
///   （Overlay.qml:266-277 的 for + break）。
/// - searchScrollArea 的拖拽状态机只有一份实现：wheel_router.dart 的 SearchListDragRouter。
///   本层 press / drag / release / cancel 全部委托给它（同一个 QML 项不允许两套真相），
///   阈值 6 与「lastDragY 只在真正发出时更新」都由它保证；本层只负责坐标空间换算与派发顺序。
/// - consumed 只表达「本层吃掉了这次 Qt 事件」，不影响 Engine 的输入看门狗
///   （Engine.cpp:711/768/796/831 由 onPositionChanged 直接喂）。
///
/// 已知偏差（本仓库无法取证，宿主可注入或需真机复核）：
/// - iOS 抬起未建模 QQuickMouseArea 的 start-drag 阈值（位移超过平台 start-drag 距离后 Qt 不再发
///   clicked）。dragThreshold <= 0 表示不建模；宿主可注入
///   QGuiApplication::styleHints()->startDragDistance() 打开该判定。
/// - iOS「是否仍在同一命中」用 HudHit 的**六字段**值相等（hud_hit.dart:21-29 只有
///   x/y/width/height/action/label；fixed 不是字段，只是 PlayerBar 序列化键），Qt 比较的是
///   活着的 delegate 对象（Overlay.qml:208-212）；命中在按下与抬起之间被重建、或两个命中的
///   六字段完全相同（几何+动作+文案一致）时无法区分，会吞掉或误发动作。
/// - 触摸按下是否让 Qt 合成 onEntered（决定 shield 与命中的 leave 是否会在触屏上发出）需真机取证；
///   本层取「触屏按入 shield 区域也立刻取消一次」的假设，见 _down 的 shield 分支。
///
/// 依赖： 共享命中模型 lib/hud/protocol/hud_hit.dart，与同目录 hit_layer.dart（几何/坐标换算）。
library;

import 'dart:ui' show Offset, Rect;

import '../protocol/hud_hit.dart';
import 'hit_layer.dart';
import 'wheel_router.dart';

/// 输入层可见的事件相位，字符串与 Qt 转发给场景的类型名一致。
class PointerPhase {
  const PointerPhase._();

  static const String down = 'pointerdown';
  static const String move = 'pointermove';
  static const String up = 'pointerup';
  static const String cancel = 'pointercancel';
  static const String leave = 'pointerleave';
  static const String pan = 'pan';

  /// 桌面 hover：进入上层 MouseArea 时对应它们的 onEntered；没有上层消费者时按 inputLayer
  /// 的 onPositionChanged 记录 pointermove（帧末 flush）。本身不是发给场景的类型名。
  static const String hover = 'hover';
}

/// 一次指针事件。[position] / [delta] 都是窗口局部逻辑坐标（QML 的 mouse.x / mouse.y）。
class PointerEvent {
  const PointerEvent({required this.phase, required this.position, this.delta = Offset.zero});

  final String phase;
  final Offset position;
  final Offset delta;
}

/// 一次转发给场景的调用（对应 rhine.pointer(type, x, y)，x/y 为舞台坐标）。
class PointerForward {
  const PointerForward(this.phase, this.x, this.y);

  final String phase;
  final double x;
  final double y;

  @override
  bool operator ==(Object other) =>
      other is PointerForward && other.phase == phase && other.x == x && other.y == y;

  @override
  int get hashCode => Object.hash(phase, x, y);

  @override
  String toString() => 'PointerForward($phase $x,$y)';
}

/// 事件最终落在哪一层，便于测试与宿主断言。
class PointerLayer {
  const PointerLayer._();

  static const String none = 'none';
  static const String playerControl = 'playerControl';
  static const String searchScroll = 'searchScroll';
  static const String hit = 'hit';
  static const String shield = 'shield';
  static const String inputLayer = 'inputLayer';
}

/// 宿主端口：副作用全部注入，路由本身不碰 UI。
abstract class PointerPorts {
  /// 触发命中动作（对应 QML 的 rhine.action(action)）。
  void action(String action);

  /// 转发给场景（对应 rhine.pointer(type, x, y)，x/y 为舞台坐标）。
  void pointer(String type, double x, double y);

  /// 转发滚轮/拖拽（对应 rhine.wheelInput(x, y, pixelDelta, angleDelta)，x/y 为舞台坐标）。
  void wheel(double x, double y, double pixelDelta, double angleDelta);

  /// 把焦点交给输入层（对应 QML 的 inputLayer.forceActiveFocus()）。
  void focusInputLayer();
}

/// searchScrollArea 的输入状态，全部来自 rhine.state（Overlay.qml:224-229 / :237 / :245 / :263）。
///
/// stageX/stageY/stageWidth/stageHeight 是 state.searchListX/searchListY/searchListWidth/
/// searchListHeight，舞台坐标；modalOffset 是 state.modalOffset。可见性由 modal 决定：
/// modal 为 search 或 saved 时可见且 enabled（Overlay.qml:224-225）。
class SearchScrollState {
  const SearchScrollState({
    this.stageX = 0.0,
    this.stageY = 0.0,
    this.stageWidth = 0.0,
    this.stageHeight = 0.0,
    this.modalOffset = 0.0,
    this.visible = false,
    this.closing = false,
  });

  final double stageX;
  final double stageY;
  final double stageWidth;
  final double stageHeight;
  final double modalOffset;
  final bool visible;
  final bool closing;

  /// Overlay.qml:226-229 —— x、y 加 modalOffset、宽高照抄（舞台坐标）。
  Rect get stageRect =>
      Rect.fromLTWH(stageX, stageY + modalOffset, stageWidth, stageHeight);
}

/// 指针路由的判定结果，便于测试断言。
class PointerOutcome {
  const PointerOutcome({
    this.action,
    this.forwards = const <PointerForward>[],
    this.consumed = false,
    this.layer = PointerLayer.none,
    this.wheel,
  });

  /// 触发的动作（命中动作或 player:seek/volume-fraction:...）。
  final String? action;

  /// searchScrollArea 拖拽产生的 wheelInput（Overlay.qml:252-259）；其它层为 null。
  ///
  /// 真正的副作用已由 SearchListDragRouter 通过 ports 发出，这里只是可断言记录。
  final WheelForward? wheel;

  /// 按序转发给场景的调用（含非 move 相位前先 flush 出来的 move）。
  final List<PointerForward> forwards;

  final bool consumed;

  /// 事件被哪一层接手。
  final String layer;
}

/// 指针路由器：只做判定与转发，任何副作用都走 [PointerPorts]。
class PointerRouter {
  PointerRouter({
    required this.hitLayer,
    required this.ports,
    this.ios = false,
    this.dragThreshold = 0.0,
  });

  /// 从唯一 [StageGeometry] 构造路由。
  ///
  /// 与绘制层使用同一个 geometry；本工厂只把它交给 HitLayer，不再另算 scale。
  factory PointerRouter.fromGeometry({
    required StageGeometry geometry,
    required PointerPorts ports,
    required bool android,
    bool ios = false,
    double dragThreshold = 0.0,
  }) {
    return PointerRouter(
      hitLayer: HitLayer(geometry: geometry, android: android),
      ports: ports,
      ios: ios,
      dragThreshold: dragThreshold,
    );
  }

  final HitLayer hitLayer;
  final PointerPorts ports;

  /// overlay.ios（Overlay.qml:27-37）。刻意与 hitLayer.android 分开：Qt 侧也是两个独立属性。
  final bool ios;

  /// QQuickMouseArea 的 start-drag 距离（逻辑像素）。<= 0 表示不建模，见头注。
  final double dragThreshold;

  /// searchScrollArea 的输入状态，宿主每帧从 rhine.state 同步。
  SearchScrollState searchScroll = const SearchScrollState();

  List<HudHit> _hits = const <HudHit>[];
  Map<String, Rect> _playerControls = const <String, Rect>{};

  String _layer = PointerLayer.none;
  HudHit? _pressedHit;
  Offset _pressedHitPoint = Offset.zero;
  String? _pressedControl;
  HudHit? _hoverHit;
  bool _searchEntered = false;
  bool _shielded = false;

  /// Engine.cpp:1042-1049 的记录位；初值与 Engine 的成员默认值一致（0,0 且未待处理）。
  double _lastX = 0.0;
  double _lastY = 0.0;
  bool _pending = false;

  /// searchScrollArea 的拖拽状态机（Overlay.qml:232-259）——唯一实现在 wheel_router.dart。
  late final SearchListDragRouter _dragRouter = SearchListDragRouter(
    geometry: hitLayer.geometry,
    ports: _PointerWheelPorts(ports),
  );

  bool _pinchActive = false;

  /// viewer 捏合是否激活（Overlay.qml 的 viewerPinch.active）。
  bool get pinchActive => _pinchActive;

  /// 输入层当前持有按下态。
  bool get inputLayerPressed => _layer == PointerLayer.inputLayer;

  /// 是否有待 flush 的 move（Engine.cpp 的 m_pointerPending）。
  bool get movePending => _pending;

  void updateHits(List<HudHit> hits) {
    _hits = hits;
  }

  /// 播放控件区域：键为 seek / volume，值为 state.seek / state.volume 的**舞台坐标**原矩形。
  ///
  /// 可见性与 enabled 由宿主决定（Overlay.qml:485-486 的 visible/enabled），不可用时应从表里
  /// 移除；iOS 只有 seek（Overlay.qml:486 的 model）。
  ///
  /// **插入顺序不参与命中裁决**：重叠时哪个控件胜出由 [_controlPriority] 固定
  /// （volume 压过 seek，与 Overlay.qml:485-508 的声明顺序一致），宿主按任意顺序放进 Map
  /// 都不会改变结果。这里保留 Map 只是为了让宿主用键名寻址。
  void updatePlayerControls(Map<String, Rect> stageRegions) {
    _playerControls = stageRegions;
  }

  /// Overlay.qml:319-323 —— 捏合激活的瞬间发一次 pointercancel(0,0)。
  ///
  /// 激活期间 inputLayer 的按下/移动/抬起三条通路同时短路（Overlay.qml:95/101/107）。
  /// 返回的 forwards 在 false -> true 的那一次包含该 cancel。
  PointerOutcome setPinchActive(bool active) {
    final wasActive = _pinchActive;
    _pinchActive = active;
    if (active && !wasActive) {
      // Engine.cpp:1050-1052 —— pointercancel 是非 move 相位，Engine 会先 flushPointer 再转发。
      final flushed = flush();
      ports.pointer(PointerPhase.cancel, 0, 0);
      return PointerOutcome(
        consumed: true,
        layer: PointerLayer.inputLayer,
        forwards: _then(flushed, const PointerForward(PointerPhase.cancel, 0, 0)),
      );
    }
    return const PointerOutcome();
  }

  /// Engine.cpp:653-659 flushPointer —— 帧末取出待处理的 move；没有则空。
  ///
  /// 宿主必须每帧调用一次（Engine 在 Engine.cpp:567/750 的帧循环里调），否则 move 不会发出。
  List<PointerForward> flush() {
    if (!_pending) {
      return const <PointerForward>[];
    }
    _pending = false;
    ports.pointer(PointerPhase.move, _lastX, _lastY);
    return <PointerForward>[PointerForward(PointerPhase.move, _lastX, _lastY)];
  }

  /// Engine.cpp:1042-1061 的入口。
  PointerOutcome handle(PointerEvent event) {
    switch (event.phase) {
      case PointerPhase.down:
        return _down(event);
      case PointerPhase.move:
        return _move(event);
      case PointerPhase.up:
        return _up(event);
      case PointerPhase.hover:
        return _hover(event);
      case PointerPhase.cancel:
        return _cancel();
      case PointerPhase.leave:
        return _leave();
      case PointerPhase.pan:
        return _pan(event);
      default:
        return const PointerOutcome();
    }
  }

  PointerOutcome _down(PointerEvent event) {
    final flushed = flush();

    final control = _controlAt(event.position);
    if (control != null) {
      // Overlay.qml:505-507 —— 按下即 adjustPlayer，拖动时每一步都重算。
      _layer = PointerLayer.playerControl;
      _pressedControl = control;
      return _adjust(control, event.position, flushed);
    }

    if (searchScroll.visible &&
        HitLayer.containsClosed(searchScroll.stageRect, hitLayer.geometry.toStage(event.position))) {
      // Overlay.qml:236-243 —— 按下即吞掉；closing 时 QML 直接 return，锚点与 dragged 都不动。
      _layer = PointerLayer.searchScroll;
      _dragRouter.press(
        localY: _localSearchStage(event.position).dy,
        closing: searchScroll.closing,
      );
      return PointerOutcome(
          consumed: true, layer: PointerLayer.searchScroll, forwards: flushed);
    }

    final hit = hitLayer.hitAt(_hits, event.position);
    if (hit != null) {
      // Overlay.qml:196-204 —— delegate.onPressed 先把焦点交给输入层。
      ports.focusInputLayer();
      _layer = PointerLayer.hit;
      _pressedHit = hit;
      _pressedHitPoint = event.position;
      if (HitLayer.firesOnPress(ios: ios)) {
        ports.action(hit.action);
        return PointerOutcome(
            consumed: true, action: hit.action, layer: PointerLayer.hit, forwards: flushed);
      }
      return PointerOutcome(consumed: true, layer: PointerLayer.hit, forwards: flushed);
    }

    if (hitLayer.isShieldedLogical(event.position)) {
      // Overlay.qml:134-139 —— shield 进入时先 cancel 再 leave，坐标固定 0,0；onPressed 只夺焦点。
      // 触屏没有 hover，故按入也视为一次进入（见头注的已知偏差），保证每次按入都先取消输入层手势。
      ports.focusInputLayer();
      _layer = PointerLayer.shield;
      if (!_shielded) {
        _shielded = true;
        return PointerOutcome(
            consumed: true, layer: PointerLayer.shield, forwards: _shield(flushed));
      }
      return PointerOutcome(consumed: true, layer: PointerLayer.shield, forwards: flushed);
    }

    _shielded = false;
    _layer = PointerLayer.inputLayer;
    ports.focusInputLayer();
    if (_pinchActive) {
      // Overlay.qml:92-97 —— 焦点先夺，随后捏合激活则不再转发。
      return PointerOutcome(
          consumed: true, layer: PointerLayer.inputLayer, forwards: flushed);
    }
    final stage = hitLayer.geometry.toStage(event.position);
    // Engine.cpp:1053-1058 —— pointerdown 只 flushPointer 再转发，**不**写 m_pointerX/Y、
    // 也不把 m_pointerPending 置真；记录位留给后续 pointermove 自己填。
    ports.pointer(PointerPhase.down, stage.dx, stage.dy);
    return PointerOutcome(
      consumed: true,
      layer: PointerLayer.inputLayer,
      forwards: _then(flushed, PointerForward(PointerPhase.down, stage.dx, stage.dy)),
    );
  }

  PointerOutcome _move(PointerEvent event) {
    switch (_layer) {
      case PointerLayer.playerControl:
        final control = _pressedControl;
        if (control == null) {
          return const PointerOutcome(consumed: true, layer: PointerLayer.playerControl);
        }
        return _adjust(control, event.position, const <PointerForward>[]);
      case PointerLayer.searchScroll:
        return _searchScrollMove(event);
      case PointerLayer.hit:
        // delegate 持有 grab，移动全被它吃掉，不会再落到 inputLayer（Overlay.qml:197-218）。
        return const PointerOutcome(consumed: true, layer: PointerLayer.hit);
      case PointerLayer.shield:
        return const PointerOutcome(consumed: true, layer: PointerLayer.shield);
      case PointerLayer.inputLayer:
        if (_pinchActive) {
          // Overlay.qml:100-105 —— 捏合期间移动同样短路（Qt 在被吞掉时不产生 move）。
          return const PointerOutcome(consumed: true, layer: PointerLayer.inputLayer);
        }
        final stage = hitLayer.geometry.toStage(event.position);
        // Engine.cpp:1043-1049 —— 坐标相同且没有待处理状态时丢弃；否则只记录、等帧末 flush。
        // move 相位不产生任何即时转发，同一帧内的多次 move 会合并（见 flush 的注释）。
        if (stage.dx == _lastX && stage.dy == _lastY && !_pending) {
          return const PointerOutcome(consumed: true, layer: PointerLayer.inputLayer);
        }
        _lastX = stage.dx;
        _lastY = stage.dy;
        _pending = true;
        return const PointerOutcome(consumed: true, layer: PointerLayer.inputLayer);
      default:
        return const PointerOutcome();
    }
  }

  PointerOutcome _up(PointerEvent event) {
    final flushed = flush();
    final layer = _layer;
    final pressed = _pressedHit;
    final pressedPoint = _pressedHitPoint;
    final dragged = _dragRouter.dragged;
    _layer = PointerLayer.none;
    _pressedHit = null;
    _pressedControl = null;
    // Overlay.qml:262 —— onReleased 无条件把 pressed 清掉（dragged 留到下一次 press 再归零）。
    _dragRouter.release(closing: searchScroll.closing);
    // Overlay.qml:134-137 —— 一次手势结束后允许下一次按入重新取消（触屏没有 hover 离开）。
    _shielded = false;

    switch (layer) {
      case PointerLayer.playerControl:
        // 抬起不再重算，Qt 的 onReleased 没有分支（Overlay.qml:505-507）。
        return PointerOutcome(
            consumed: true, layer: PointerLayer.playerControl, forwards: flushed);
      case PointerLayer.searchScroll:
        return _searchScrollUp(event, dragged, flushed);
      case PointerLayer.hit:
        if (!HitLayer.firesOnPress(ios: ios)) {
          // Overlay.qml:208-212 —— iOS 只有 onClicked，且释放点必须仍在同一命中内。
          // dragThreshold > 0 时先过 QQuickMouseArea 的 start-drag 判定（见头注）。
          final moved = (event.position - pressedPoint).distance;
          final withinDrag = dragThreshold <= 0.0 || moved < dragThreshold;
          final hit = hitLayer.hitAt(_hits, event.position);
          if (withinDrag && hit != null && hit == pressed) {
            ports.action(hit.action);
            return PointerOutcome(
                consumed: true,
                action: hit.action,
                layer: PointerLayer.hit,
                forwards: flushed);
          }
        }
        return PointerOutcome(consumed: true, layer: PointerLayer.hit, forwards: flushed);
      case PointerLayer.shield:
        return PointerOutcome(consumed: true, layer: PointerLayer.shield, forwards: flushed);
      case PointerLayer.inputLayer:
        if (_pinchActive) {
          // Overlay.qml:106-110 —— 捏合期间抬起短路。
          return PointerOutcome(
              consumed: true, layer: PointerLayer.inputLayer, forwards: flushed);
        }
        final stage = hitLayer.geometry.toStage(event.position);
        // Engine.cpp:1050-1052 —— 非 move 相位只 flushPointer 再转发，同样不碰记录位。
        ports.pointer(PointerPhase.up, stage.dx, stage.dy);
        return PointerOutcome(
          consumed: true,
          layer: PointerLayer.inputLayer,
          forwards: _then(flushed, PointerForward(PointerPhase.up, stage.dx, stage.dy)),
        );
      default:
        return PointerOutcome(forwards: flushed);
    }
  }

  /// 桌面 hover：searchScrollArea / 命中 delegate 的 onEntered 发 pointerleave(0,0)
  /// （Overlay.qml:235 / :201）；shield 的 onEntered 发 cancel + leave（Overlay.qml:134-137）。
  ///
  /// 没有被上层吃掉的 hover 移动落在 inputLayer 上：它有 hoverEnabled（Overlay.qml:89），
  /// onPositionChanged 无条件转发 pointermove（:100-105 没有 pressed 守卫）。因此这里与
  /// [_move] 一样**只记录、不转发**，由宿主的帧末 flush() 合成一次 pointermove
  /// （Engine.cpp:1043-1049 记录、:653-659 帧末发出）。反过来，落在 hit / shield /
  /// searchScrollArea 上的 hover 不再传下去：三者都是 hoverEnabled 的上层 MouseArea
  /// （Overlay.qml:185-218 / :123-142 / :222-284），只定义了 onEntered，没有转发
  /// onPositionChanged 的路径。
  ///
  /// flush 只落在真正要发 leave / cancel 的分支里：Engine.cpp:1050-1052 只对非 move 相位
  /// 先 flushPointer，纯 hover 移动不会把上一条待发的 move 提前顶出去。
  ///
  /// 已知偏差：seek/volume 也是 hoverEnabled 的上层 MouseArea（Overlay.qml:485-508），
  /// 在它们的矩形内 hover 不会落到 inputLayer；本层不建模控件 hover（触屏没有 hover，
  /// 控件只由 _down 的 playerControl 分支处理），桌面鼠标路径上这一条顺序差异保留。
  PointerOutcome _hover(PointerEvent event) {
    if (searchScroll.visible &&
        HitLayer.containsClosed(searchScroll.stageRect, hitLayer.geometry.toStage(event.position))) {
      _hoverHit = null;
      if (!_searchEntered) {
        _searchEntered = true;
        final flushed = flush();
        ports.pointer(PointerPhase.leave, 0, 0);
        return PointerOutcome(
          consumed: true,
          layer: PointerLayer.searchScroll,
          forwards: _then(flushed, const PointerForward(PointerPhase.leave, 0, 0)),
        );
      }
      return const PointerOutcome(consumed: true, layer: PointerLayer.searchScroll);
    }
    _searchEntered = false;

    final hit = hitLayer.hitAt(_hits, event.position);
    if (hit != null) {
      final entered = _hoverHit != hit;
      _hoverHit = hit;
      _shielded = false;
      if (entered) {
        final flushed = flush();
        ports.pointer(PointerPhase.leave, 0, 0);
        return PointerOutcome(
          consumed: true,
          layer: PointerLayer.hit,
          forwards: _then(flushed, const PointerForward(PointerPhase.leave, 0, 0)),
        );
      }
      return const PointerOutcome(consumed: true, layer: PointerLayer.hit);
    }
    _hoverHit = null;
    if (hitLayer.isShieldedLogical(event.position)) {
      if (!_shielded) {
        _shielded = true;
        final flushed = flush();
        return PointerOutcome(
            consumed: true, layer: PointerLayer.shield, forwards: _shield(flushed));
      }
      return const PointerOutcome(consumed: true, layer: PointerLayer.shield);
    }
    _shielded = false;
    if (_pinchActive) {
      // Overlay.qml:100-105 —— 捏合激活时 onPositionChanged 直接 return，不产生 move。
      return const PointerOutcome(consumed: true, layer: PointerLayer.inputLayer);
    }
    final stage = hitLayer.geometry.toStage(event.position);
    // Engine.cpp:1043-1049 —— 同坐标且没有待处理状态时丢弃；否则只记录并置 pending。
    if (stage.dx != _lastX || stage.dy != _lastY || _pending) {
      _lastX = stage.dx;
      _lastY = stage.dy;
      _pending = true;
    }
    return const PointerOutcome(consumed: true, layer: PointerLayer.inputLayer);
  }

  /// inputLayer 的 onExited（Overlay.qml:112）：只 flush + 转发 pointerleave(0,0)。
  ///
  /// Qt 在这里没有任何状态副作用：mouse 的 grab 与 pressed 都保持，后续 pointermove
  /// 照样进 onPositionChanged（继续按 Engine.cpp:1042-1049 记录），所以本层也不复位
  /// _layer/_pressedHit，也不复位 _dragRouter 的拖拽态。宿主只在「输入层自身退出」时送入该相位。
  PointerOutcome _leave() {
    final flushed = flush();
    ports.pointer(PointerPhase.leave, 0, 0);
    return PointerOutcome(
      consumed: true,
      layer: _layer == PointerLayer.none ? PointerLayer.inputLayer : _layer,
      forwards: _then(flushed, const PointerForward(PointerPhase.leave, 0, 0)),
    );
  }

  /// inputLayer 的 onCanceled（Overlay.qml:113）：转发 pointercancel(0,0) 并复位按下态。
  ///
  /// 与 [_leave] 的区别见头注：cancel 才是这次手势的终点，之后不应再按旧层继续派发。
  PointerOutcome _cancel() {
    final flushed = flush();
    final layer = _layer;
    _layer = PointerLayer.none;
    _pressedHit = null;
    _pressedControl = null;
    _shielded = false;
    _dragRouter.cancel();
    ports.pointer(PointerPhase.cancel, 0, 0);
    return PointerOutcome(
      consumed: true,
      layer: layer == PointerLayer.none ? PointerLayer.inputLayer : layer,
      forwards: _then(flushed, const PointerForward(PointerPhase.cancel, 0, 0)),
    );
  }

  /// Overlay.qml:303-317 的 forwardPan。
  PointerOutcome _pan(PointerEvent event) {
    final flushed = flush();
    if (!_pinchActive) {
      // Overlay.qml:304-307 —— forwardPan 在 handler 未激活时直接返回。
      return PointerOutcome(
          consumed: true, layer: PointerLayer.inputLayer, forwards: flushed);
    }
    final geometry = hitLayer.geometry;
    final dx = event.delta.dx;
    final dy = event.delta.dy;
    if (dx == 0.0 && dy == 0.0) {
      return PointerOutcome(
          consumed: true, layer: PointerLayer.inputLayer, forwards: flushed);
    }
    // Overlay.qml:313-314 的量纲不一致原样保留：dx 对舞台宽度、dy 对窗口高度。
    if (dx.abs() > 0.4 * geometry.stageWidth || dy.abs() > 0.4 * geometry.logicalHeight) {
      return PointerOutcome(
          consumed: true, layer: PointerLayer.inputLayer, forwards: flushed);
    }
    // 这里只消费唯一注入的 geometry.stageScale（PortraitStage 那一份），
    // 不在路由层按窗口高度重新推导，也不乘第二次。
    final scale = geometry.stageScale;
    ports.pointer(PointerPhase.pan, dx / scale, dy / scale);
    return PointerOutcome(
      consumed: true,
      layer: PointerLayer.inputLayer,
      forwards: _then(flushed, PointerForward(PointerPhase.pan, dx / scale, dy / scale)),
    );
  }

  PointerOutcome _searchScrollMove(PointerEvent event) {
    // Overlay.qml:244-261 —— 这条路径发的是 wheelInput，不是 Engine::pointer，
    // 所以既不 flush 记录位、也不产生 pointermove。
    final wheel = _dragRouter.drag(
      local: _localSearchStage(event.position),
      stageOrigin: Offset(searchScroll.stageX, searchScroll.stageY + searchScroll.modalOffset),
      scale: hitLayer.geometry.stageScale,
      closing: searchScroll.closing,
    );
    if (wheel == null) {
      return const PointerOutcome(consumed: true, layer: PointerLayer.searchScroll);
    }
    return PointerOutcome(
      consumed: true,
      layer: PointerLayer.searchScroll,
      wheel: wheel,
    );
  }

  PointerOutcome _searchScrollUp(PointerEvent event, bool dragged, List<PointerForward> flushed) {
    if (searchScroll.closing || dragged) {
      // Overlay.qml:262-265 —— closing 或已拖拽的抬起什么都不做。
      return PointerOutcome(
          consumed: true, layer: PointerLayer.searchScroll, forwards: flushed);
    }
    // Overlay.qml:266-270 —— px/py 与 hitArea(hit) 同在「不含 modalOffset」的舞台空间。
    final stage = hitLayer.geometry.toStage(event.position);
    final scanPoint = Offset(stage.dx, stage.dy - searchScroll.modalOffset);
    final hit = hitLayer.firstResultHit(_hits, scanPoint);
    if (hit == null) {
      return PointerOutcome(
          consumed: true, layer: PointerLayer.searchScroll, forwards: flushed);
    }
    ports.action(hit.action);
    return PointerOutcome(
      consumed: true,
      action: hit.action,
      layer: PointerLayer.searchScroll,
      forwards: flushed,
    );
  }

  /// 逻辑点 -> searchScrollArea 的局部坐标（= 舞台单位，因为该 item 位于 scale=stageScale 的
  /// controls 之内，Overlay.qml:179-184/226-227）。
  Offset _localSearchStage(Offset logicalPoint) {
    final stage = hitLayer.geometry.toStage(logicalPoint);
    return Offset(stage.dx - searchScroll.stageX, stage.dy - searchScroll.stageY - searchScroll.modalOffset);
  }

  PointerOutcome _adjust(String control, Offset logicalPoint, List<PointerForward> flushed) {
    final region = _playerControls[control];
    if (region == null) {
      return PointerOutcome(
          consumed: true, layer: PointerLayer.playerControl, forwards: flushed);
    }
    final stage = hitLayer.geometry.toStage(logicalPoint);
    final action = HitLayer.playerFractionAction(
      control: control,
      x: stage.dx - region.left,
      width: region.width,
    );
    if (action == null) {
      return PointerOutcome(
          consumed: true, layer: PointerLayer.playerControl, forwards: flushed);
    }
    ports.action(action);
    return PointerOutcome(
        consumed: true, action: action, layer: PointerLayer.playerControl, forwards: flushed);
  }

  /// Overlay.qml:485-508 的声明顺序 —— 后声明者在上层，所以 volume 在 seek 之上。
  ///
  /// 顺序写死在这里而不是依赖宿主 Map 的插入顺序：QML 的层叠关系由 Repeater 的 model
  /// 顺序固定（Overlay.qml:486 `model: ["seek", "volume"]`），宿主换个顺序传 Map 时
  /// 「两控件重叠的窄条上 volume 胜出」必须不受影响。表里没有的键（将来新增控件）排在
  /// 已知控件之下，不抢 seek / volume 的命中。
  static const List<String> _controlPriority = <String>['seek', 'volume'];

  /// 最上层（[_controlPriority] 里序数最大）包含该点的播放控件名，无则 null。
  String? _controlAt(Offset logicalPoint) {
    if (_playerControls.isEmpty) {
      return null;
    }
    final stage = hitLayer.geometry.toStage(logicalPoint);
    String? found;
    // -1 = 未知控件（最低层），-2 = 尚未命中。
    var foundRank = -2;
    for (final entry in _playerControls.entries) {
      if (!HitLayer.containsClosed(hitLayer.playerControlRect(entry.value), stage)) {
        continue;
      }
      final rank = _controlPriority.indexOf(entry.key);
      if (rank > foundRank) {
        found = entry.key;
        foundRank = rank;
      }
    }
    return found;
  }

  static List<PointerForward> _then(List<PointerForward> flushed, PointerForward forward) {
    if (flushed.isEmpty) {
      return <PointerForward>[forward];
    }
    return <PointerForward>[...flushed, forward];
  }

  /// Overlay.qml:134-137 —— cancel 在前、leave 在后，坐标固定 0,0。
  static List<PointerForward> _shield(List<PointerForward> flushed) {
    final cancel = const PointerForward(PointerPhase.cancel, 0, 0);
    final leave = const PointerForward(PointerPhase.leave, 0, 0);
    if (flushed.isEmpty) {
      return <PointerForward>[cancel, leave];
    }
    return <PointerForward>[...flushed, cancel, leave];
  }
}

/// 把 [PointerPorts] 适配成 [SearchListDragRouter] 需要的 [WheelPorts]。
///
/// 两者签名相同（x, y, pixelDelta, angleDelta 都是舞台坐标），只差方法名；
/// 适配器让 searchScrollArea 的拖拽只有一份实现，同时保持 PointerPorts 只有一个轮子入口。
class _PointerWheelPorts implements WheelPorts {
  const _PointerWheelPorts(this.ports);

  final PointerPorts ports;

  @override
  void wheelInput(double x, double y, double pixelDelta, double angleDelta) =>
      ports.wheel(x, y, pixelDelta, angleDelta);
}
