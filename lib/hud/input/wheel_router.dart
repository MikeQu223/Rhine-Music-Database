/// 滚轮输入路由：Qt/qml/Overlay.qml、Qt/qml/TouchInput.qml 的滚轮入口，
/// Qt/src/Engine.cpp:1013-1015 与 :1062-1086 的累积器，以及 Qt/src/NativeHudInput.cpp:9-179
/// （NativeHud::wheel）的 1:1 迁移。滚动数学来自 Qt/src/HudScroll.h:11-41。
///
/// 三层结构与 Qt 实际调用链一致，不得合并：
///   1. OverlayWheelRouter / SearchListDragRouter / TouchDragRouter
///      —— QML 事件层：把逻辑坐标换算成舞台坐标后调用 rhine.wheelInput(...)。
///   2. EngineWheelAccumulator —— Engine 层：wheelInput 拆 pixelDelta/angleDelta，
///      wheel() 把一次事件折算成 steps + distance，tick 内按 WHEEL_SMOOTHING 衰减后再发。
///   3. HudWheelRouter —— NativeHud::wheel：按 modal/mode 分派到各面板的偏移。
///
/// 不可变约束（逐条有 Qt 出处）：
/// - QML 只把 x/y 除以 stageScale；pixelDelta / angleDelta 原样透传（Overlay.qml:114-117、
///   :213-217、:279-283）。TouchInput 却把 translation 的差分量也除以 stageScale
///   （TouchInput.qml:23）——两处量纲不一致，原样保留、不修正。
/// - playerBarInputShield 的滚轮只置 accepted，不转发任何事件（Overlay.qml:139-141）。
/// - searchScrollArea 的拖动转滚轮：阈值 6 逻辑像素、delta 是本次与上次拖动点在 inputLayer
///   内的 y 差、angleDelta 恒 0、lastDragY 只在真正发出时更新（Overlay.qml:244-261）。
/// - viewer 捏合把捏合比取自然对数乘 350 当 pixelDelta（Overlay.qml:330-340）；350 是把捏合比
///   换算成与桌面滚轮同速的常数（源自 NativeViewer 的 pow(0.95, 0.7*|delta|*0.01) 与
///   -delta*8），原样保留。
/// - Engine：pixelDelta != 0 走像素通路（steps += -delta/WHEEL_STEP_PIXELS，
///   distance += -delta/(height/1080)），否则走离散通路（steps += delta<0?1:-1，
///   distance = -delta/15*80）；reduced 时直接累 distance，否则进待衰减的 remaining
///   （Engine.cpp:1069-1083）。非有限值或 delta==0 直接丢弃（:1063）。
/// - 衰减：|remaining| < 6 时整段送出，否则送 0.5 份；每 tick 最后 int(steps) 取整下发并把余数
///   留回（Engine.cpp:752-766）。WHEEL_STEP_PIXELS 在 Android 上是 75、其它平台 15
///   （:176/:178）。
/// - NativeHud::wheel 的分派顺序固定：frame 空 → playerBounds → 空事件 → settings →
///   desktop-lyrics → viewer → !modal.isEmpty()（playlist-picker / discover / player /
///   search / saved）→ 歌词浏览 → detail 非歌曲 → detail 其它 → archive / 场景滚轮
///   （NativeHudInput.cpp:11-178）。
/// - settings 分支先无条件 cancelSettingEdit()，再判断包围盒；desktop-lyrics 无此步；
///   两者都要求 !closing（NativeHudInput.cpp:23-48）。search/saved 分支先做 y -= motion.offset
///   再判包围盒（:86、:107）。saved 分支同样有完整包围盒判断（:108-111）——旧草稿漏掉了
///   这一条，此处按原文补回。
/// - QRectF::contains 含边界（NativeHudInput.cpp:14 的 playerBounds、:63 的 discover viewport），
///   而 dart:ui 的 Rect.contains 是右/下半开；本层一律用 hit_layer.dart 的 HitLayer.containsClosed，
///   与命中层同源、也与 Qt 的闭区间一致。直接用 Rect.contains 会把正好落在 right/bottom 边上的
///   滚轮判丢（与 hit_layer 头注 :21-23 是同一条理由）。
///
/// 依赖：同目录 hit_layer.dart 的 StageGeometry（舞台/逻辑坐标换算的唯一实现）。
library;

import 'dart:math' as math;
import 'dart:ui' show Offset, Rect;

import 'hit_layer.dart';

// 第 1 层：QML 事件层

/// 滚轮事件来自哪一层，便于宿主断言与测试。字符串与 QML 的 id/objectName 对齐。
class WheelSurface {
  const WheelSurface._();

  /// Overlay.qml:86 的 inputLayer。
  static const String inputLayer = 'inputLayer';

  /// Overlay.qml:197-218 的命中 delegate。
  static const String hit = 'hit';

  /// Overlay.qml:124 的 playerBarInputShield（只吞不转发）。
  static const String playerShield = 'playerBarInputShield';

  /// Overlay.qml:223 的 searchScrollArea。
  static const String searchScrollArea = 'searchScrollArea';

  /// TouchInput.qml:8 的 DragHandler。
  static const String touchDrag = 'touchDrag';

  /// Overlay.qml:293 的 viewerPinch。
  static const String viewerPinch = 'viewerPinch';
}

/// 一次滚轮事件的 QML 原始形态：QWheelEvent 的两条增量（Overlay.qml:115）。
///
/// 高精度触控板给 pixelDelta，普通鼠标给 angleDelta（一格 120）；Engine 侧优先 pixelDelta
/// （Engine.cpp:1014）。两者都是窗口（逻辑）像素，不是舞台像素。
class WheelDelta {
  const WheelDelta({this.pixelDeltaY = 0.0, this.angleDeltaY = 0.0});

  /// QWheelEvent.pixelDelta.y。
  final double pixelDeltaY;

  /// QWheelEvent.angleDelta.y。
  final double angleDeltaY;

  static const WheelDelta none = WheelDelta();
}

/// 一次对 rhine.wheelInput(...) 的调用，x/y 为舞台坐标（Overlay.qml:115）。
class WheelForward {
  const WheelForward(
    this.surface,
    this.x,
    this.y,
    this.pixelDeltaY,
    this.angleDeltaY,
  );

  final String surface;
  final double x;
  final double y;
  final double pixelDeltaY;
  final double angleDeltaY;

  @override
  bool operator ==(Object other) =>
      other is WheelForward &&
      other.surface == surface &&
      other.x == x &&
      other.y == y &&
      other.pixelDeltaY == pixelDeltaY &&
      other.angleDeltaY == angleDeltaY;

  @override
  int get hashCode => Object.hash(surface, x, y, pixelDeltaY, angleDeltaY);

  @override
  String toString() =>
      'WheelForward(' + surface + ' ' + x.toString() + ',' + y.toString() +
      ' pixel=' + pixelDeltaY.toString() + ' angle=' + angleDeltaY.toString() + ')';
}

/// 滚轮侧的副作用端口：只有「把一次滚轮交给引擎」这一个入口
/// （对应 QML 的 rhine.wheelInput，Qt/src/Engine.cpp:1013）。
abstract class WheelPorts {
  /// 对应 rhine.wheelInput(x, y, pixelDelta, angleDelta)；x/y 为舞台坐标。
  void wheelInput(double x, double y, double pixelDelta, double angleDelta);
}

/// QML 滚轮入口：inputLayer、命中 delegate、shield、viewer 捏合。
class OverlayWheelRouter {
  const OverlayWheelRouter({required this.geometry, required this.ports});

  final StageGeometry geometry;
  final WheelPorts ports;

  /// Overlay.qml:339 的 350：把捏合比换成与桌面滚轮同速的换算常数。原样保留。
  static const double pinchToWheelScale = 350.0;

  /// Overlay.qml:114-117 —— inputLayer 的滚轮：x/y 除 stageScale，两条增量原样透传。
  WheelForward inputLayerWheel(Offset logical, WheelDelta delta) {
    final stage = geometry.toStage(logical);
    return _emit(WheelSurface.inputLayer, stage, delta.pixelDeltaY, delta.angleDeltaY);
  }

  /// Overlay.qml:213-217 与 :279-283 —— 命中 delegate / searchScrollArea 的滚轮。
  ///
  /// QML 先 mapToItem(inputLayer, wheel.x, wheel.y) 再除以 stageScale：事件的坐标是
  /// **delegate 局部坐标**，delegate 位于 controls 内（controls 原点在 inputLayer 原点、
  /// 按 stageScale 缩放、transformOrigin 为 TopLeft，Overlay.qml:179-184），所以
  /// 逻辑坐标 = (stageOrigin + local) * stageScale，stageOrigin 是该命中在舞台坐标里的左上角
  /// （Overlay.qml:190-193 的 area.x / area.y + modalOffset）。
  ///
  /// [surface] 区分 Overlay 的两条同构路径：命中 delegate（:213-217）与 searchScrollArea
  /// （:279-283）。两者换算逐字相同，只有 surface 标签不同——但它是「这次滚轮由哪一层吃掉」
  /// 的唯一证据，宿主日志与测试都靠它分辨，所以不做默认合并。
  WheelForward hitWheel({
    required Offset local,
    required Offset stageOrigin,
    required double scale,
    required WheelDelta delta,
    String surface = WheelSurface.hit,
  }) {
    final logical = mapToInputLayer(stageOrigin: stageOrigin, scale: scale, local: local);
    final stage = geometry.toStage(logical);
    return _emit(surface, stage, delta.pixelDeltaY, delta.angleDeltaY);
  }

  /// QML mapToItem(inputLayer, local) 的等价换算。
  Offset mapToInputLayer({
    required Offset stageOrigin,
    required double scale,
    required Offset local,
  }) =>
      Offset((stageOrigin.dx + local.dx) * scale, (stageOrigin.dy + local.dy) * scale);

  /// Overlay.qml:139-141 —— playerBarInputShield 的滚轮只置 accepted，不产生任何转发。
  ///
  /// 返回 true 表示该滚轮被吞掉（QML 里就是 wheel.accepted = true）。
  bool shieldWheel() => true;

  /// Overlay.qml:330-340 —— viewer 捏合比 → 滚轮。
  ///
  /// Math.log(delta) * 350：delta 是 Qt 6 的 scaleChanged(delta)（这一帧捏合距离的乘法变化量），
  /// 350 把「捏合比的自然对数」线性映射成与桌面滚轮同样的缩放速度
  /// （注释原文见 Overlay.qml:334-336）。守卫条件同样逐字保留：!active、非有限、<= 0 都不发。
  WheelForward? viewerPinchWheel({
    required bool active,
    required bool viewer,
    required double delta,
    required Offset centroidLogical,
  }) {
    // Overlay.qml:331 —— pinch handler 只在 viewer 打开时 enabled（:297），
    // 这里仍以 viewer 显式收口，避免调用方漏传。
    if (!active || !viewer || delta.isNaN || delta.isInfinite || delta <= 0.0) {
      return null;
    }
    // Math.log(1) == 0 时 QML 照样调用 wheelInput（它没有 delta!=0 的判断），此处照做。
    final scaleFactor = math.log(delta);
    final stage = geometry.toStage(centroidLogical);
    return _emit(WheelSurface.viewerPinch, stage, scaleFactor * pinchToWheelScale, 0.0);
  }

  WheelForward _emit(String surface, Offset stage, double pixelDelta, double angleDelta) {
    ports.wheelInput(stage.dx, stage.dy, pixelDelta, angleDelta);
    return WheelForward(surface, stage.dx, stage.dy, pixelDelta, angleDelta);
  }
}

/// Overlay.qml:222-284 的 searchScrollArea：按住拖动 → 滚轮。
///
/// 逐条对应：
/// - onPressed（:236-243）：closing 时不进入拖动，dragOriginY = lastDragY = mouse.y，
///   dragged = false。
/// - onPositionChanged（:244-261）：!pressed || closing 直接返回；
///   mouse.y - dragOriginY| > 6 才置 dragged；dragged 后取 p 与 previous 两点在 inputLayer
///   的 y 差，delta != 0 才 wheelInput(p.x/scale, p.y/scale, delta, 0)，并且只在发出时把
///   lastDragY 更新成当前 mouse.y。
/// - onReleased（:262-278）：closing 或 dragged 时不发命中（命中判定属 hit_layer，不在本层）。
class SearchListDragRouter {
  SearchListDragRouter({required this.geometry, required this.ports});

  final StageGeometry geometry;
  final WheelPorts ports;

  /// Overlay.qml:248 的拖动阈值，单位是 delegate 局部（逻辑）像素。
  static const double dragThresholdY = 6.0;

  double _dragOriginY = 0.0;
  double _lastDragY = 0.0;
  bool _dragged = false;
  bool _pressed = false;

  /// 是否已越过 6px 阈值（Overlay.qml:262 的 dragged）。
  bool get dragged => _dragged;

  /// Overlay.qml:238-242。closing 时 QML 直接 return，既不记锚点也不置 pressed。
  void press({required double localY, required bool closing}) {
    if (closing) {
      return;
    }
    _dragOriginY = localY;
    _lastDragY = localY;
    _dragged = false;
    _pressed = true;
  }

  /// Overlay.qml:244-261。返回本次实际发出的滚轮（没发则 null）。
  WheelForward? drag({
    required Offset local,
    required Offset stageOrigin,
    required double scale,
    required bool closing,
  }) {
    // Overlay.qml:245-247
    if (!_pressed || closing) {
      return null;
    }
    if ((local.dy - _dragOriginY).abs() > dragThresholdY) {
      _dragged = true;
    }
    if (!_dragged) {
      return null;
    }
    final current =
        Offset((stageOrigin.dx + local.dx) * scale, (stageOrigin.dy + local.dy) * scale);
    final previous =
        Offset((stageOrigin.dx + local.dx) * scale, (stageOrigin.dy + _lastDragY) * scale);
    final delta = current.dy - previous.dy;
    if (delta == 0.0) {
      // Overlay.qml:256 —— delta 为 0 时不发，也不更新 lastDragY。
      return null;
    }
    final stage = geometry.toStage(current);
    // Overlay.qml:257 —— delta 原样作为 pixelDelta 传入，**不除 stageScale**（与 x/y 的处理
    // 不同）。Qt 自身就是这样：mapToItem 出来的 y 差是窗口像素，Engine.cpp:1072 再按
    // height/1080 换算成舞台位移。原样保留、不修正。
    ports.wheelInput(stage.dx, stage.dy, delta, 0.0);
    _lastDragY = local.dy;
    return WheelForward(WheelSurface.searchScrollArea, stage.dx, stage.dy, delta, 0.0);
  }

  /// Overlay.qml:262-264（onReleased 的前半段）。
  ///
  /// QML 里 `if (closing || dragged) return;` 之后的命中派发属于 hit_layer 的职责，
  /// 本层只负责清 pressed；因此这里不分支——既没有吞掉什么，也不会多发任何事件。
  /// （原样保留：closing 时同样清 pressed，否则下一次 press 之前的状态会脏。）
  void release({required bool closing}) {
    _pressed = false;
  }

  void cancel() {
    _pressed = false;
    _dragged = false;
  }
}

/// TouchInput.qml:8-25 的 DragHandler：单指拖动 → 滚轮。
///
/// 与 Overlay 的区别（原样保留、不修正）：这里把 translation 的差分量**也**除以 stageScale
/// （TouchInput.qml:23），于是 pixelDelta 已经是舞台像素，Engine.cpp:1072 会再除一次
/// height/1080。这是 Qt 既有的量纲不一致，照抄。
class TouchDragRouter {
  TouchDragRouter({required this.geometry, required this.ports});

  final StageGeometry geometry;
  final WheelPorts ports;

  bool _active = false;
  double _previousY = 0.0;

  bool get active => _active;

  /// TouchInput.qml:13-15 —— 是否接管触摸：
  /// iOS 只在有弹层或处于 detail 时接管（主场景留给系统返回手势）；Android 全程接管；
  /// viewer 打开时整个 handler 让位（单指拖动是球面旋转，滚轮是缩放，两者不能叠加）。
  static bool captures({
    required bool ios,
    required bool android,
    required String modal,
    required String mode,
    required bool viewer,
  }) {
    final platformTakes = ios ? (modal.isNotEmpty || mode == 'detail') : android;
    return platformTakes && !viewer;
  }

  /// TouchInput.qml:18 —— onActiveChanged 时 previousY 归零。
  void begin() {
    _active = true;
    _previousY = 0.0;
  }

  void end() {
    _active = false;
  }

  /// TouchInput.qml:19-25 —— 返回本次发出的滚轮（未激活则 null）。
  WheelForward? update({required Offset centroidLogical, required double translationY}) {
    if (!_active) {
      return null;
    }
    final delta = translationY - _previousY;
    _previousY = translationY;
    final stage = geometry.toStage(centroidLogical);
    final pixelDelta = delta / geometry.stageScale;
    ports.wheelInput(stage.dx, stage.dy, pixelDelta, 0.0);
    return WheelForward(WheelSurface.touchDrag, stage.dx, stage.dy, pixelDelta, 0.0);
  }
}

// 第 2 层：Engine 累积器（Engine.cpp:1013-1015、:1062-1086、:752-766、:569-572）

/// Engine.cpp:171-185 的编译期常量。
class EngineWheelConstants {
  const EngineWheelConstants._();

  /// Engine.cpp:176 —— Android 上把「翻一首歌」的距离放大 5 倍（15 → 75），
  /// 避免手指滑动误触切歌；只影响 steps，不影响 distance 那条连续滚动通路。
  static const double stepPixelsAndroid = 75.0;

  /// Engine.cpp:178 —— 其它平台。
  static const double stepPixelsOther = 15.0;

  /// Engine.cpp:181 —— 鼠标滚轮一格折算的内容距离（约一行）。
  static const double distancePerNotch = 80.0;

  /// Engine.cpp:183 —— 离散事件按帧衰减，约 0.1 秒内收束。
  static const double smoothing = 0.5;

  /// Engine.cpp:185 —— 尾段直接送出，避免浮点衰减无限拖延。
  static const double distanceTail = 6.0;

  /// Engine.cpp:1077 —— 离散通路里「一格滚轮 = 15 个步进单位」的除数。
  static const double notchDivisor = 15.0;

  /// Engine.cpp:1072 —— 像素通路的舞台基准高度。
  static const double stageBaseHeight = 1080.0;

  static double stepPixels({required bool android}) =>
      android ? stepPixelsAndroid : stepPixelsOther;
}

/// 一次下发给 NativeHud::wheel 的事件（Engine.cpp:762 的实参表）。
class HudWheelEvent {
  const HudWheelEvent({
    required this.x,
    required this.y,
    required this.delta,
    required this.steps,
    required this.distance,
  });

  /// 舞台坐标（QML 已除过 stageScale）。
  final double x;
  final double y;

  /// 本 tick 累积的原始 delta（下发后清零）。
  final double delta;

  /// int(m_wheelSteps)：行/首歌的整数步进。
  final int steps;

  /// m_wheelDistance：连续舞台位移。
  final double distance;

  @override
  String toString() =>
      'HudWheelEvent(' + x.toString() + ',' + y.toString() + ' delta=' +
      delta.toString() + ' steps=' + steps.toString() + ' distance=' +
      distance.toString() + ')';
}

/// Engine.cpp:1062-1086 的 wheel() 累积 + :752-766 的 tick 衰减下发。
///
/// Qt 侧这些是 Engine 的成员变量；这里做成一个显式对象，宿主每帧调用 [flushTick]。
class EngineWheelAccumulator {
  EngineWheelAccumulator({
    required this.android,
    required this.reduced,
    required this.logicalHeight,
  });

  /// Engine.cpp:175-179 的平台分支。
  final bool android;

  /// app->hud.reduced（Engine.cpp:1078）。
  bool reduced;

  /// m_height：Engine.cpp:1072 的 m_height / 1080。
  double logicalHeight;

  double _x = 0.0;
  double _y = 0.0;
  double _delta = 0.0;
  double _steps = 0.0;
  double _distance = 0.0;
  double _remainingDistance = 0.0;
  bool _pending = false;

  /// 是否还有未下发的事件（Engine.cpp:711 的 inputPending 之一）。
  bool get pending => _pending;

  /// Engine.cpp:1013-1015 —— pixelDelta 优先；非零时走像素通路（pixels = true）。
  void wheelInput(double x, double y, double pixelDelta, double angleDelta) {
    final pixels = pixelDelta != 0.0;
    wheel(x, y, pixels ? pixelDelta : angleDelta / 8.0, pixels: pixels);
  }

  /// Engine.cpp:1062-1086。
  void wheel(double x, double y, double delta, {required bool pixels}) {
    // Engine.cpp:1063 —— 非有限值或 0 直接丢弃（在写 m_wheelX/Y 之前）。
    if (delta.isNaN || delta.isInfinite || delta == 0.0) {
      return;
    }
    _x = x;
    _y = y;
    _delta += delta;
    if (pixels) {
      // Engine.cpp:1071
      _steps += -delta / EngineWheelConstants.stepPixels(android: android);
      // Engine.cpp:1072 —— 连续舞台位移按 height/1080 换算。Qt 对 height 为 0 没有保护
      // （会得到 inf），这里同样不夹取，由下游 isFinite 判断兜住。
      _distance += -delta / (logicalHeight / EngineWheelConstants.stageBaseHeight);
    } else {
      // Engine.cpp:1075
      _steps += delta < 0.0 ? 1.0 : -1.0;
      // Engine.cpp:1077
      final distance =
          -delta / EngineWheelConstants.notchDivisor * EngineWheelConstants.distancePerNotch;
      if (reduced) {
        _distance += distance;
      } else {
        _remainingDistance += distance;
      }
    }
    _pending = true;
  }

  /// Engine.cpp:752-766 —— 每 tick 取一次；没有待发事件返回 null。
  HudWheelEvent? flushTick() {
    if (_remainingDistance != 0.0) {
      final portion = _remainingDistance.abs() < EngineWheelConstants.distanceTail
          ? _remainingDistance
          : _remainingDistance * EngineWheelConstants.smoothing;
      _distance += portion;
      _remainingDistance -= portion;
      _pending = true;
    }
    if (!_pending) {
      return null;
    }
    // Engine.cpp:761 —— int(m_wheelSteps) 向零截断；余数留回累积器（:763）。
    final steps = _steps.toInt();
    final event = HudWheelEvent(
      x: _x,
      y: _y,
      delta: _delta,
      steps: steps,
      distance: _distance,
    );
    _steps -= steps;
    _pending = false;
    _delta = 0.0;
    _distance = 0.0;
    return event;
  }

  /// Engine.cpp:569-572 的复位。
  void reset() {
    _delta = 0.0;
    _steps = 0.0;
    _distance = 0.0;
    _remainingDistance = 0.0;
    _pending = false;
  }
}

// 第 3 层：NativeHud::wheel（NativeHudInput.cpp:9-179）

/// Qt/src/HudScroll.h:11-26 的滚动数学。只迁移输入消费侧用到的三个函数。
///
/// clipHits（HudScroll.h:67-86）属 hit 产出侧（各卡片绘制时裁剪命中表），不在输入消费侧，
/// 因此不在此实现，避免与  的命中模型产生第二份真相。
class HudScroll {
  const HudScroll._();

  /// HudScroll.h:11。
  static const double defaultWheelStep = 60.0;

  /// HudScroll.h:13-15。
  static double maximum(double contentHeight, double viewportHeight) =>
      math.max(0.0, contentHeight - viewportHeight);

  /// HudScroll.h:17-19。Qt 的 std::clamp 对 NaN 未定义；这里保守返回 0
  /// （Qt 侧不会出现 NaN，因为 delta 已判 isfinite，且 offsets 由本层夹取）。
  static double clampOffset(double offset, double contentHeight, double viewportHeight) {
    final upper = maximum(contentHeight, viewportHeight);
    if (offset.isNaN) {
      return 0.0;
    }
    return offset.clamp(0.0, upper).toDouble();
  }

  /// HudScroll.h:22-26 —— distance 有值**且不为 0** 时用距离，否则退回 steps * stepPixels。
  static double applyWheel(
    double offset,
    double contentHeight,
    double viewportHeight,
    double? distance,
    int steps,
    double stepPixels,
  ) {
    final movement = (distance != null && distance != 0.0) ? distance : steps * stepPixels;
    return clampOffset(offset + movement, contentHeight, viewportHeight);
  }
}

/// NativeHud.h:37-127 的视口/行高常量与 NativeHudInput.cpp 的字面量。
class HudWheelConstants {
  const HudWheelConstants._();

  /// NativeHud.h:96-98。
  static const double resultListTop = 328.0;
  static const double resultListBottom = 758.0;
  static const double resultRowHeight = 72.0;

  /// NativeHud.h:115-116。
  static const double settingsViewportTop = 176.0;
  static const double settingsViewportBottom = 836.0;

  /// NativeHud.h:126-127。
  static const double desktopLyricsViewportTop = 200.0;
  static const double desktopLyricsViewportBottom = 820.0;

  /// NativeHud.h:108。
  static const int albumTrackRowCount = 6;

  /// NativeHudInput.cpp:33、:45 —— 设置页与桌面歌词的方向步进。
  static const double settingsStepPixels = 66.0;
  static const double desktopLyricsStepPixels = 66.0;

  /// NativeHudInput.cpp:64 —— discover 的平滑步长。
  static const double discoverStepPixels = 60.0;

  /// NativeHudInput.cpp:69 —— discover 触底补页阈。
  static const double discoverLoadMoreMargin = 120.0;

  /// NativeHudInput.cpp:97、:116 —— 结果列表触底补页阈。
  static const double listLoadMoreMargin = 160.0;

  /// NativeHudInput.cpp:29、:40、:87、:108 —— x 方向的左右内缩。
  static const double modalLeftInset = 53.0;
  static const double modalRightInset = 10.0;

  /// NativeHudInput.cpp:57 —— 歌单选择器可见行数：lists[2].size() - 7。
  static const int pickerVisibleRows = 7;

  /// NativeHudInput.cpp:122 —— 歌词浏览区：右半屏、y ∈ [360, 889)。
  static const double lyricsBrowseXFraction = 0.56;
  static const double lyricsBrowseTop = 360.0;
  static const double lyricsBrowseBottom = 889.0;

  /// NativeHudInput.cpp:124 —— (-delta / 120) * 65。
  static const double lyricsBrowseNotch = 120.0;
  static const double lyricsBrowseStep = 65.0;

  /// NativeHudInput.cpp:167 —— body 换行宽度与可见行数。
  static const double bodyWrapWidthFactor = 0.44;
  static const double bodyWrapInset = 59.0;
  static const double bodyWrapFontSize = 16.0;
  static const int bodyVisibleRows = 3;

  /// NativeHudInput.cpp:51、:177 —— viewer/场景滚轮的换算 -delta * 8。
  static const double sceneWheelScale = 8.0;

  /// NativeHud.h:37-47 的 containerLayout 缺省值（宿主可覆盖）。
  static const double layoutLeft = 40.0;
  static const double layoutSidebar = 250.0;
  static const double layoutX = 326.0;
  static const double layoutTop = 260.0;
  static const double layoutRowsY = 434.0;
  static const double layoutRowHeight = 54.0;
  static const int layoutRowCount = 9;
  static const double layoutBottom = 956.0;
}

/// NativeHud.h:37-47 的 containerLayout(width) 结果（由布局侧发布，本层不重算）。
class HudContainerLayout {
  const HudContainerLayout({
    this.left = HudWheelConstants.layoutLeft,
    this.sidebar = HudWheelConstants.layoutSidebar,
    this.x = HudWheelConstants.layoutX,
    this.width = 0.0,
    this.top = HudWheelConstants.layoutTop,
    this.rowsY = HudWheelConstants.layoutRowsY,
    this.rowHeight = HudWheelConstants.layoutRowHeight,
    this.rowCount = HudWheelConstants.layoutRowCount,
    this.bottom = HudWheelConstants.layoutBottom,
  });

  final double left;
  final double sidebar;
  final double x;
  final double width;
  final double top;
  final double rowsY;
  final double rowHeight;
  final int rowCount;
  final double bottom;
}

/// 被 NativeHud::wheel 就地修改的滚动偏移（Qt 里是 NativeHud 的成员变量）。
///
/// 单独抽出来是为了让路由保持无状态、可重复断言；Qt 的字段类型逐个对齐：
/// listOffset / queueOffset / trackOffset / bodyOffset / m_lyricsPlainOffset 是 int，
/// 其余是 double，m_lyricsBrowse 是 std::optional<double>。
class HudScrollOffsets {
  HudScrollOffsets({
    this.settingsScroll = 0.0,
    this.desktopLyricsScroll = 0.0,
    this.listOffset = 0,
    this.discoverScroll = 0.0,
    this.queueOffset = 0,
    this.searchScroll = 0.0,
    this.savedScroll = 0.0,
    this.trackOffset = 0,
    this.bodyOffset = 0,
    this.lyricsScroll = 0.0,
    this.lyricsBrowse,
    this.lyricsPlainOffset = 0,
  });

  double settingsScroll;
  double desktopLyricsScroll;
  int listOffset;
  double discoverScroll;
  int queueOffset;
  double searchScroll;
  double savedScroll;
  int trackOffset;
  int bodyOffset;

  /// NativeHud.h:226 的 m_lyricsScroll：m_lyricsBrowse.value_or(m_lyricsScroll) 的回退值。
  double lyricsScroll;

  /// NativeHud.h:227 的 std::optional<double> m_lyricsBrowse。
  double? lyricsBrowse;

  /// NativeHud.h:232 的 int m_lyricsPlainOffset。
  int lyricsPlainOffset;
}

/// 区域名，与 Qt 的各面板一一对应（用于测试断言与宿主日志）。
class WheelRegion {
  const WheelRegion._();

  static const String none = 'none';
  static const String settings = 'settings';
  static const String desktopLyrics = 'desktop-lyrics';
  static const String viewer = 'viewer';
  static const String playlistPicker = 'playlist-picker';
  static const String discover = 'discover';
  static const String playerQueue = 'player';
  static const String search = 'search';
  static const String saved = 'saved';
  static const String lyricsBrowse = 'lyrics-browse';
  static const String detailList = 'detail-list';
  static const String detailBody = 'detail-body';
  static const String archive = 'archive';
  static const String scene = 'scene';
}

/// NativeHud::wheel 需要读取的状态投影。字段全部来自 frame/state 与布局发布，
/// 本层不新增真相（弹层矩形与 containerLayout 都是布局的产物，见各字段注释）。
class HudWheelSnapshot {
  const HudWheelSnapshot({
    this.frameEmpty = false,
    this.modal = '',
    this.closing = false,
    this.viewer = false,
    this.modalOffset = 0.0,
    this.editingSetting = false,
    this.playerBounds,
    this.modalBounds = Rect.zero,
    this.discoverViewport = Rect.zero,
    this.categoryPicker = false,
    this.discoverScrollMaximum = 0.0,
    this.discoverLoading = false,
    this.discoverMore = false,
    this.searchRowCount = 0,
    this.searchQueryMatchesKeyword = false,
    this.searchSourceLoading = false,
    this.searchHasMore = false,
    this.savedRowCount = 0,
    this.savedHasMore = false,
    this.savedCollection = 1,
    this.queueMaximumOffset = 0,
    this.pickerRowCount = 0,
    this.lyricsMode = false,
    this.currentKind = '',
    this.stageWidth = 0.0,
    this.lyricsLastTop = 0.0,
    this.mode = '',
    this.tab = 'overview',
    this.directoryKind,
    this.artistTab = 'songs',
    this.directoryAlbumsCount,
    this.directorySongsCount,
    this.tracksCount = 0,
    this.settingsContentBottom = 1600.0,
    this.desktopLyricsContentBottom = 1600.0,
    this.containerLayout = const HudContainerLayout(),
    this.bodyLineCount = 0,
  });

  /// frame.isEmpty()（NativeHudInput.cpp:11）。
  final bool frameEmpty;
  final String modal;
  final bool closing;

  /// frame["viewer"].toBool()（NativeHudInput.cpp:49）。
  final bool viewer;

  /// motion.offset：弹层入场位移，弹层内坐标要先减掉它（:28、:39、:63、:86、:107）。
  final double modalOffset;

  /// !editingSettingId.isEmpty()（:24）。
  final bool editingSetting;

  /// state.playerBounds，舞台坐标；存在即整块区域吃下滚轮（:14）。
  final Rect? playerBounds;

  /// modalBounds(width)（布局产物，:27、:38、:85、:106）。
  final Rect modalBounds;

  /// DiscoverMusicCard::layout(bounds, items.size()).viewport（:62）。
  final Rect discoverViewport;

  final bool categoryPicker;
  final double discoverScrollMaximum;
  final bool discoverLoading;
  final bool discoverMore;

  final int searchRowCount;

  /// query.trimmed() == music.keyword（:98）。
  final bool searchQueryMatchesKeyword;
  final bool searchSourceLoading;

  /// music.hasMore[0]（:98）。
  final bool searchHasMore;

  final int savedRowCount;

  /// music.hasMore[musicCollection]（:117）。
  final bool savedHasMore;
  final int savedCollection;

  /// PlaybackQueueCard::maximumOffset(queue.size())（:78）。
  final int queueMaximumOffset;

  /// music.lists[2].size()（:57）。
  final int pickerRowCount;

  final bool lyricsMode;

  /// music.current["kind"]（:122、:129）。
  final String currentKind;

  /// NativeHud::width —— 歌词浏览区的 x 阈值是 width * 0.56（:122）。
  final double stageWidth;

  /// m_lyricsLayout.isEmpty() ? 0 : constLast().top（:123）。
  final double lyricsLastTop;

  /// frame["mode"]（:129、:157、:172）。
  final String mode;

  /// NativeHud.h:77 的 tab（缺省 "overview"）—— detail 正文分支用它判断 history
  /// （NativeHudInput.cpp:162）。注意不是 artistTab。
  final String tab;

  /// music.directory ? music.directory->item["kind"] : null（:140）。
  final String? directoryKind;

  /// artistTab（:140）。
  final String artistTab;

  /// music.directory->albums.size() / ->songs.size()（:143）。
  final int? directoryAlbumsCount;
  final int? directorySongsCount;

  /// music.tracks.size()（:141、:164）。
  final int tracksCount;

  /// NativeHud.h:117 的 settingsContentBottom（布局发布）。
  final double settingsContentBottom;

  /// NativeHud.h:128 的 desktopLyricsContentBottom（布局发布）。
  final double desktopLyricsContentBottom;

  /// containerLayout(width)（:134）。
  final HudContainerLayout containerLayout;

  /// glyphs.wrap(body(), width * 0.44 - 59, 16).size()（:167）。
  final int bodyLineCount;
}

/// NativeHud::wheel 的副作用端口：每个方法对应 Qt 里一处真正的调用。
abstract class HudWheelPorts {
  /// NativeHudInput.cpp:25 —— 设置页有未提交编辑时先取消。
  void cancelSettingEdit();

  /// :51、:177 —— m_scene.pointer("wheel", x, y, delta)。
  void sceneWheel(double x, double y, double delta);

  /// :71 —— music.discover->load(tab, true)。
  void loadDiscoverMore();

  /// :99、:118 —— music.loadMoreSource(index)。
  void loadMoreSource(int collection);

  /// :148 —— music.loadArtistAlbums()。
  void loadArtistAlbums();

  /// :150 —— music.loadDirectoryPage()。
  void loadDirectoryPage();

  /// :152、:165 —— music.loadTrackPage(offset)。
  void loadTrackPage(int offset);

  /// :174 —— music.next(step)。
  void musicNext(int step);
}

/// NativeHud::wheel 的判定结果。副作用已经通过 [HudWheelPorts] 发出，
/// 这里保留区域名与效果清单，方便静态审查与测试断言。
class HudWheelOutcome {
  const HudWheelOutcome({
    this.region = WheelRegion.none,
    this.consumed = false,
    this.effects = const <String>[],
  });

  final String region;

  /// true 表示这次事件已被某个分支接住（Qt 里就是某个分支的 return）。
  /// 全局早退（frame 空、playerBounds、空事件）为 false。
  final bool consumed;

  /// 按发生顺序记录的效果名，仅供诊断。
  final List<String> effects;

  @override
  String toString() =>
      'HudWheelOutcome(' + region + ' consumed=' + consumed.toString() +
      ' effects=' + effects.toString() + ')';
}

/// NativeHud::wheel（NativeHudInput.cpp:9-179）的 1:1 迁移。
///
/// 顺序、阈值、量纲与 Qt 完全一致；每一段都注明出处行号。
class HudWheelRouter {
  const HudWheelRouter({required this.ports});

  final HudWheelPorts ports;

  /// 入口。
  ///
  /// x/y 是舞台坐标，delta/steps/distance 与 NativeHud::wheel 的三个量一一对应：
  /// steps 为 null 时由 delta 的符号推导（NativeHudInput.cpp:17），distance 为 null
  /// 表示本帧没有平滑距离（Engine 的 reduced 关闭时通常会有）。
  HudWheelOutcome route(
    HudWheelSnapshot s,
    HudScrollOffsets offsets, {
    required double x,
    required double y,
    required double delta,
    int? steps,
    double? distance,
  }) {
    // NativeHudInput.cpp:11 —— frame 空或 delta 非有限值。
    if (s.frameEmpty || delta.isNaN || delta.isInfinite) {
      return const HudWheelOutcome();
    }
    // NativeHudInput.cpp:14 —— playerBounds 命中即整块吞掉（对应 QML 的 shield）。
    final player = s.playerBounds;
    if (player != null && HitLayer.containsClosed(player, Offset(x, y))) {
      return const HudWheelOutcome();
    }
    // NativeHudInput.cpp:17
    final step = steps ?? (delta < 0.0 ? 1 : -1);
    // NativeHudInput.cpp:19
    if (delta == 0.0 && step == 0 && (distance ?? 0.0) == 0.0) {
      return const HudWheelOutcome();
    }

    // NativeHudInput.cpp:23-36 —— settings。顺序要点：先无条件取消编辑，再判包围盒。
    if (s.modal == 'settings') {
      final effects = <String>[];
      if (s.editingSetting) {
        ports.cancelSettingEdit();
        effects.add('cancelSettingEdit');
      }
      final bounds = s.modalBounds;
      final localY = y - s.modalOffset;
      if (!s.closing &&
          x >= bounds.left + HudWheelConstants.modalLeftInset &&
          x <= bounds.right - HudWheelConstants.modalLeftInset &&
          localY >= bounds.top + HudWheelConstants.settingsViewportTop &&
          localY <= bounds.top + HudWheelConstants.settingsViewportBottom) {
        // :29-35
        offsets.settingsScroll = HudScroll.applyWheel(
          offsets.settingsScroll,
          s.settingsContentBottom - HudWheelConstants.settingsViewportTop,
          HudWheelConstants.settingsViewportBottom - HudWheelConstants.settingsViewportTop,
          distance,
          step,
          HudWheelConstants.settingsStepPixels,
        );
        effects.add('settingsScroll');
      }
      return HudWheelOutcome(
        region: WheelRegion.settings,
        consumed: true,
        effects: effects,
      );
    }
    // NativeHudInput.cpp:37-48 —— desktop-lyrics（无 cancelSettingEdit）。
    if (s.modal == 'desktop-lyrics') {
      final bounds = s.modalBounds;
      final localY = y - s.modalOffset;
      final effects = <String>[];
      if (!s.closing &&
          x >= bounds.left + HudWheelConstants.modalLeftInset &&
          x <= bounds.right - HudWheelConstants.modalLeftInset &&
          localY >= bounds.top + HudWheelConstants.desktopLyricsViewportTop &&
          localY <= bounds.top + HudWheelConstants.desktopLyricsViewportBottom) {
        offsets.desktopLyricsScroll = HudScroll.applyWheel(
          offsets.desktopLyricsScroll,
          s.desktopLyricsContentBottom - HudWheelConstants.desktopLyricsViewportTop,
          HudWheelConstants.desktopLyricsViewportBottom -
              HudWheelConstants.desktopLyricsViewportTop,
          distance,
          step,
          HudWheelConstants.desktopLyricsStepPixels,
        );
        effects.add('desktopLyricsScroll');
      }
      return HudWheelOutcome(
        region: WheelRegion.desktopLyrics,
        consumed: true,
        effects: effects,
      );
    }
    // NativeHudInput.cpp:49-54 —— viewer：滚轮是缩放，delta == 0 时不发。
    if (s.viewer) {
      final effects = <String>[];
      if (delta != 0.0) {
        ports.sceneWheel(x, y, -delta * HudWheelConstants.sceneWheelScale);
        effects.add('sceneWheel');
      }
      return HudWheelOutcome(
        region: WheelRegion.viewer,
        consumed: true,
        effects: effects,
      );
    }

    // NativeHudInput.cpp:55-121 —— 弹层内部。顺序与 Qt 的 if 链完全一致。
    if (s.modal.isNotEmpty) {
      // :56-59 playlist-picker：没有包围盒判断，只夹上下限。
      if (s.modal == 'playlist-picker') {
        final upper = math.max(0, s.pickerRowCount - HudWheelConstants.pickerVisibleRows);
        offsets.listOffset = (offsets.listOffset + step).clamp(0, upper).toInt();
        return const HudWheelOutcome(
          region: WheelRegion.playlistPicker,
          consumed: true,
          effects: <String>['listOffset'],
        );
      }
      // :60-75 discover。
      if (s.modal == 'discover') {
        final viewport = s.discoverViewport;
        final effects = <String>[];
        final localY = y - s.modalOffset;
        if (!s.closing &&
            !s.categoryPicker &&
            HitLayer.containsClosed(viewport, Offset(x, localY))) {
          final movement = distance ?? step * HudWheelConstants.discoverStepPixels;
          // :65 —— 内容高度是 viewport.height() + discoverScrollMaximum。
          offsets.discoverScroll = HudScroll.applyWheel(
            offsets.discoverScroll,
            viewport.height + s.discoverScrollMaximum,
            viewport.height,
            distance,
            step,
            HudWheelConstants.discoverStepPixels,
          );
          effects.add('discoverScroll');
          // :69-72
          if (movement > 0 &&
              offsets.discoverScroll >=
                  s.discoverScrollMaximum - HudWheelConstants.discoverLoadMoreMargin &&
              !s.discoverLoading &&
              s.discoverMore) {
            ports.loadDiscoverMore();
            effects.add('loadDiscoverMore');
          }
        }
        return HudWheelOutcome(
          region: WheelRegion.discover,
          consumed: true,
          effects: effects,
        );
      }
      // :76-80 player（队列）。
      if (s.modal == 'player') {
        offsets.queueOffset = (offsets.queueOffset + step)
            .clamp(0, math.max(0, s.queueMaximumOffset))
            .toInt();
        return const HudWheelOutcome(
          region: WheelRegion.playerQueue,
          consumed: true,
          effects: <String>['queueOffset'],
        );
      }
      // :81-102 search。
      if (s.modal == 'search') {
        if (s.closing) {
          return const HudWheelOutcome(region: WheelRegion.search, consumed: true);
        }
        final bounds = s.modalBounds;
        final localY = y - s.modalOffset;
        final inside = x >= bounds.left + HudWheelConstants.modalLeftInset &&
            x <= bounds.right - HudWheelConstants.modalRightInset &&
            localY >= bounds.top + HudWheelConstants.resultListTop &&
            localY <= bounds.top + HudWheelConstants.resultListBottom;
        if (!inside) {
          return const HudWheelOutcome(region: WheelRegion.search, consumed: true);
        }
        final effects = <String>[];
        final movement = distance ?? step * HudWheelConstants.resultRowHeight;
        offsets.searchScroll = HudScroll.applyWheel(
          offsets.searchScroll,
          s.searchRowCount * HudWheelConstants.resultRowHeight,
          HudWheelConstants.resultListBottom - HudWheelConstants.resultListTop,
          distance,
          step,
          HudWheelConstants.resultRowHeight,
        );
        effects.add('searchScroll');
        // :97-100；searchScrollMaximum() 见 NativeHudSearch.cpp:255-257。
        final maximum = HudScroll.maximum(
          s.searchRowCount * HudWheelConstants.resultRowHeight,
          HudWheelConstants.resultListBottom - HudWheelConstants.resultListTop,
        );
        if (movement > 0 &&
            offsets.searchScroll >= maximum - HudWheelConstants.listLoadMoreMargin &&
            s.searchQueryMatchesKeyword &&
            !s.searchSourceLoading &&
            s.searchHasMore) {
          ports.loadMoreSource(0);
          effects.add('loadMoreSource');
        }
        return HudWheelOutcome(
          region: WheelRegion.search,
          consumed: true,
          effects: effects,
        );
      }
      // :103-120 saved。Qt 这里同样有完整包围盒判断（旧草稿漏了）。
      // :103 的 `if (modal != "saved" || closing) return;`——未知弹层落到这里直接返回，
      // 既不滚动也不落到场景滚轮（整条 if 链在 :121 收尾）。
      if (s.modal != 'saved') {
        return const HudWheelOutcome(consumed: true);
      }
      if (s.closing) {
        return const HudWheelOutcome(region: WheelRegion.saved, consumed: true);
      }
      final bounds = s.modalBounds;
      final localY = y - s.modalOffset;
      final inside = x >= bounds.left + HudWheelConstants.modalLeftInset &&
          x <= bounds.right - HudWheelConstants.modalRightInset &&
          localY >= bounds.top + HudWheelConstants.resultListTop &&
          localY <= bounds.top + HudWheelConstants.resultListBottom;
      if (!inside) {
        return const HudWheelOutcome(region: WheelRegion.saved, consumed: true);
      }
      final effects = <String>[];
      final movement = distance ?? step * HudWheelConstants.resultRowHeight;
      offsets.savedScroll = HudScroll.applyWheel(
        offsets.savedScroll,
        s.savedRowCount * HudWheelConstants.resultRowHeight,
        HudWheelConstants.resultListBottom - HudWheelConstants.resultListTop,
        distance,
        step,
        HudWheelConstants.resultRowHeight,
      );
      effects.add('savedScroll');
      final maximum = HudScroll.maximum(
        s.savedRowCount * HudWheelConstants.resultRowHeight,
        HudWheelConstants.resultListBottom - HudWheelConstants.resultListTop,
      );
      if (movement > 0 &&
          offsets.savedScroll >= maximum - HudWheelConstants.listLoadMoreMargin &&
          !s.searchSourceLoading &&
          s.savedHasMore) {
        ports.loadMoreSource(s.savedCollection);
        effects.add('loadMoreSource');
      }
      return HudWheelOutcome(
        region: WheelRegion.saved,
        consumed: true,
        effects: effects,
      );
    }

    // :122-128 歌词浏览区：右半屏、y ∈ [360, 889)。x 阈值对 width（舞台宽），
    // y 阈值是舞台像素；与其它分支不同，这里不减 motion.offset（Qt 原样如此）。
    if (s.lyricsMode &&
        s.currentKind == 'song' &&
        x >= s.stageWidth * HudWheelConstants.lyricsBrowseXFraction &&
        y >= HudWheelConstants.lyricsBrowseTop &&
        y < HudWheelConstants.lyricsBrowseBottom) {
      final movement = distance ??
          (-delta / HudWheelConstants.lyricsBrowseNotch) * HudWheelConstants.lyricsBrowseStep;
      // :125 —— m_lyricsBrowse.value_or(m_lyricsScroll) + movement 再夹到 [0, lastTop]。
      final base = offsets.lyricsBrowse ?? offsets.lyricsScroll;
      offsets.lyricsBrowse = (base + movement).clamp(0.0, s.lyricsLastTop).toDouble();
      // :126 —— 注意这里是 max(0, ...)，没有上界。
      offsets.lyricsPlainOffset = math.max(0, offsets.lyricsPlainOffset + step);
      return const HudWheelOutcome(
        region: WheelRegion.lyricsBrowse,
        consumed: true,
        effects: <String>['lyricsBrowse', 'lyricsPlainOffset'],
      );
    }

    // :129-156 detail 且当前不是歌曲：曲目行列表。
    if (s.mode == 'detail' && s.currentKind != 'song') {
      if (step == 0) {
        return const HudWheelOutcome(region: WheelRegion.detailList, consumed: true);
      }
      final layout = s.containerLayout;
      final inside = x >= layout.x &&
          x <= layout.x + layout.width &&
          y >= layout.rowsY &&
          y <= layout.rowsY + layout.rowCount * layout.rowHeight;
      if (!inside) {
        return const HudWheelOutcome(region: WheelRegion.detailList, consumed: true);
      }
      // :140
      final albums = s.directoryKind == 'artist' && s.artistTab == 'albums';
      // :141-143 —— 有 directory 时用目录页的条数，否则用当前已加载的 tracks。
      final count = s.directoryKind != null
          ? (albums ? (s.directoryAlbumsCount ?? 0) : (s.directorySongsCount ?? 0))
          : s.tracksCount;
      offsets.trackOffset = (offsets.trackOffset + step)
          .clamp(0, math.max(0, count - layout.rowCount))
          .toInt();
      final effects = <String>['trackOffset'];
      // :146-153
      if (offsets.trackOffset + layout.rowCount >= count) {
        if (albums) {
          ports.loadArtistAlbums();
          effects.add('loadArtistAlbums');
        } else if (s.directoryKind != null) {
          ports.loadDirectoryPage();
          effects.add('loadDirectoryPage');
        } else {
          ports.loadTrackPage(offsets.trackOffset);
          effects.add('loadTrackPage');
        }
      }
      return HudWheelOutcome(
        region: WheelRegion.detailList,
        consumed: true,
        effects: effects,
      );
    }
    // :157-171 detail 其它：history 行列表或正文。
    if (s.mode == 'detail') {
      if (step == 0) {
        return const HudWheelOutcome(region: WheelRegion.detailList, consumed: true);
      }
      final effects = <String>[];
      if (s.tab == 'history') {
        // :163-165 —— 夹到 tracks.size() - AlbumTrackRowCount，并且**无条件**
        // loadTrackPage(trackOffset + AlbumTrackRowCount - 1) 预取尾页。
        offsets.trackOffset = (offsets.trackOffset + step)
            .clamp(0, math.max(0, s.tracksCount - HudWheelConstants.albumTrackRowCount))
            .toInt();
        effects.add('trackOffset');
        ports.loadTrackPage(offsets.trackOffset + HudWheelConstants.albumTrackRowCount - 1);
        effects.add('loadTrackPage');
        return HudWheelOutcome(
          region: WheelRegion.detailList,
          consumed: true,
          effects: effects,
        );
      }
      // :167-170 —— 正文按换行后的行数滚动，视口 3 行。
      offsets.bodyOffset = (offsets.bodyOffset + step)
          .clamp(0, math.max(0, s.bodyLineCount - HudWheelConstants.bodyVisibleRows))
          .toInt();
      effects.add('bodyOffset');
      return HudWheelOutcome(
        region: WheelRegion.detailBody,
        consumed: true,
        effects: effects,
      );
    }

    // :172-178 archive 与场景滚轮。archive 只看 step，普通场景只看 delta。
    if (s.mode == 'archive') {
      if (step != 0) {
        ports.musicNext(step);
        return const HudWheelOutcome(
          region: WheelRegion.archive,
          consumed: true,
          effects: <String>['musicNext'],
        );
      }
      return const HudWheelOutcome(region: WheelRegion.archive, consumed: true);
    }
    if (delta != 0.0) {
      ports.sceneWheel(x, y, -delta * HudWheelConstants.sceneWheelScale);
      return const HudWheelOutcome(
        region: WheelRegion.scene,
        consumed: true,
        effects: <String>['sceneWheel'],
      );
    }
    return const HudWheelOutcome(consumed: true);
  }
}
