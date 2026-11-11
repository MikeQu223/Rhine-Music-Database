/// 旋转/窗口变化的「几何 + 视图状态」（纯 Dart，不 import Flutter）。
///
/// 责任边界（docs/superpowers/plans/2026-11-09-qt-to-flutter-parity-plan.md:369-376）：
/// * 只做两件事：方向判定 + stage 重算（[StageMetrics.compute] / [recomputeStage]），
///   以及跨旋转视图状态的 capture/restore（[captureOrientationState] /
///   [restoreOrientationState]）。
/// * 不持有引擎、播放器、网络、Widget 或单例；本文件没有任何可变全局状态，也没有
///   可以 dispose/清空引擎的入口，所以「旋转只允许 MediaQuery 重建与 stage 重算」
///   不依赖调用方自觉（plan:369）。
/// * 所有跨旋转持久量都活在**方向无关域**：行域（item index / row）、舞台单位、
///   文本域（字符下标）。绝对像素只在 [ScrollAnchor.pixelOffsetFor] 与
///   [resolveScrollOffsets] 的出口出现 —— 这正是方向翻转不需要「换算旧像素」的原因，
///   也是 plan:371「item key + 相对滚动偏移（不是绝对 offset）」的落法。
///
/// 字段分两类，注释逐条标明出处：
/// * Qt 持久化/运行时已有的量（stage 几何、lane、目录游标、settingsScroll、queueOffset、
///   modal、offset）给出 Qt 源行号；
/// * plan:369-376 要求、但 Qt `sessionState()`（Qt/src/MusicSession.cpp:215-234）
///   不存的量（[ScrollAnchor.withinItem]、itemKey、[CurveToken]、输入
///   selection/composing/focus）在字段注释写 plan 行，不冒充 Qt 字段；
///   [StageInsets] 来自 plan:364（安全区避让只作用于新增纵向容器），
///   devicePixelRatio 不是 plan 字段，是 Qt 运行时环境量（Qt/src/NativeSceneCamera.cpp:57
///   的物理宽判定）。
library;

import 'dart:math' as math;

// ---------------------------------------------------------------------------
// 常量（逐条带 Qt 证据；不得凭手感改数值）
// ---------------------------------------------------------------------------

/// Qt 横屏舞台**高**不变量（舞台单位）。
/// Qt/qml/Main.qml:32 "property real stageScale: height / 1080"。
const double qtStageHeightUnits = 1080;

/// 高度为 0（首帧/折叠）时 Qt 用的退化舞台宽。
/// Qt/src/Engine.cpp:1353 "m_height > 0 ? m_width / (m_height / 1080) : 1920"。
const double qtStageWidthFallbackUnits = 1920;

/// 竖屏舞台**宽**不变量（舞台单位）。
/// T43 lib/ui/layout/portrait_bands.dart:32 "portraitStageWidthConstant = 1080"；
/// T02 docs/flutter-migration/contracts/layout.md:281（§6）与 :290-292 给出同一常量与公式；
/// plan:362。这里只固定「舞台盒」的宽，不裁决 Portrait-W/Band/Hybrid
/// 谁是样板（T43 同文件:20-22 明确不裁决）。
const double portraitStageWidthUnits = 1080;

/// 竖屏判定阈值：aspect < 1.05 即竖屏。
/// Qt/src/NativeSceneCamera.cpp:55-56
/// "const auto aspect = m_width / m_height; const bool portrait = aspect < 1.05;"
/// 注意是「小于」判定：aspect 恰好 1.05 属于横屏。
const double qtPortraitAspectThreshold = 1.05;

/// 横屏「紧凑」分支阈值（只服务 3D 相机）：!portrait && m_width < 1100。
/// Qt/src/NativeSceneCamera.cpp:57。Qt 的 m_width 是渲染面**物理**像素，
/// 因此比较前也要把逻辑宽乘 devicePixelRatio（见 [StageMetrics.cameraCompact]）。
const double qtCompactPhysicalWidthThreshold = 1100;

/// 五个 lane：搜索结果 / 喜欢的歌曲 / 我的歌单 / 收藏歌单 / 收藏专辑。
/// Qt/src/MusicLibrary.h:140 "std::array<QJsonArray, 5> lists"。
const int laneCount = 5;

/// 每页 40 项：Qt/src/MusicSession.cpp:130 "folder->page = folder->index / 40 * 40"，
/// 且 selected 夹取到 [0,39]（同文件:260）。
const int pageSize = 40;

/// 一屏 8 行：目录锚点 = destination * 8 + rowMemory[destination]
/// （Qt/src/MusicDirectory.cpp:80），故 rowMemory ∈ [0,7]
/// （Qt/src/MusicSession.cpp:111 "std::clamp(..., 0, 7)"）。
const int rowsPerPage = 8;

/// 目录栈上限 64 层：Qt/src/MusicSession.cpp:43 "folders.size() < 64"；
/// 同文件:100 遇到 >64 直接拒绝整份恢复。
const int directoryStackLimit = 64;

/// 设置页视口上下边界（舞台单位）：Qt/src/NativeHud.h:115-116。
const double settingsViewportTop = 176;
const double settingsViewportBottom = 836;

/// 设置内容初始底边（舞台单位）：Qt/src/NativeHud.h:117 "settingsContentBottom = 1600"。
const double defaultSettingsContentBottom = 1600;

/// 几何浮点比较容差（与 T43 lib/ui/layout/portrait_bands.dart:38 同值）。
/// 集成收敛项（T44-82）：1080 与 1e-6 在 T43/T44 各有一份，集成后由共享常量模块做
/// 唯一真源；本值以 Qt/qml/Main.qml:32 的 1080 为准，不得各自漂移。
const double stageGeometryTolerance = 1e-6;

/// 可跨旋转恢复的 modal 白名单，恰好七项。
/// Qt/src/MusicSession.cpp:243
/// QStringList{"saved","search","discover","queue","settings","player","local"}。
/// 唯一真源（T44-82）：lib/app/rotation_continuity.dart 必须 import 本集合，不得再写一份
/// 字面量；以后若拆共享常量模块，以本文件为迁移源。
const Set<String> restorableModalNames = <String>{
  'saved',
  'search',
  'discover',
  'queue',
  'settings',
  'player',
  'local',
};

// ---------------------------------------------------------------------------
// 夹取工具（Qt 侧是 std::clamp / std::max(0, x)，这里逐条对应）
// ---------------------------------------------------------------------------

int _clampInt(int value, int minimum, int maximum) {
  if (maximum < minimum) {
    return minimum;
  }
  return value < minimum ? minimum : (value > maximum ? maximum : value);
}

double _clampDouble(double value, double minimum, double maximum) {
  if (value.isNaN) {
    return minimum;
  }
  final double top = maximum < minimum ? minimum : maximum;
  return value < minimum ? minimum : (value > top ? top : value);
}

/// Qt/src/MusicSession.cpp:28-30 "int nonnegative(const QJsonValue &value)"。
int _nonnegative(int value) => value < 0 ? 0 : value;

/// Qt HudScroll::maximum：Qt/src/HudScroll.h:13-15 "std::max(0., content - viewport)"。
double hudScrollMaximum(double contentHeight, double viewportHeight) =>
    math.max(0.0, contentHeight - viewportHeight);

/// Qt HudScroll::clampOffset：Qt/src/HudScroll.h:17-19。
double hudScrollClamp(double offset, double contentHeight, double viewportHeight) =>
    _clampDouble(offset, 0, hudScrollMaximum(contentHeight, viewportHeight));

/// 设置页滚动上限，逐字对应 Qt/src/NativeHud.h:132-135：
/// HudScroll::maximum(settingsContentBottom - SettingsViewportTop,
///                    SettingsViewportBottom - SettingsViewportTop)。
double settingsScrollMaximumFor(double contentBottom) =>
    hudScrollMaximum(contentBottom - settingsViewportTop, settingsViewportBottom - settingsViewportTop);

// ---------------------------------------------------------------------------
// 方向
// ---------------------------------------------------------------------------

/// 方向分类。只有两种取值：Qt 的 compact 分支不是第三种方向，而是横屏内的相机子分支
/// （Qt/src/NativeSceneCamera.cpp:57），见 [StageMetrics.cameraCompact]。
enum OrientationKind { landscape, portrait }

/// 纯方向判定，不需要 dpr、不需要 inset（两者都不改变宽高比）。
///
/// 证据 Qt/src/NativeSceneCamera.cpp:55-56。退化窗口（任一维 <= 0）按横屏处理，
/// 与 [StageMetrics.compute] 的退化分支保持一致。
OrientationKind classifyOrientation({required double logicalWidth, required double logicalHeight}) {
  if (!(logicalWidth > 0) || !(logicalHeight > 0)) {
    return OrientationKind.landscape;
  }
  return logicalWidth / logicalHeight < qtPortraitAspectThreshold
      ? OrientationKind.portrait
      : OrientationKind.landscape;
}

// ---------------------------------------------------------------------------
// stage 度量
// ---------------------------------------------------------------------------

/// 四边安全区 + IME 高度，单位统一按**逻辑像素**接收。
///
/// Qt 横屏完全没有 inset 处理（T43 lib/ui/layout/portrait_bands.dart:14-15 已核对）；
/// plan:364 要求「安全区避让只作用于新增纵向容器；IME 不缩放 stage」。扣减层因此固定为：
/// * IME 永不参与 stageScale/stageWidth/stageHeight，只经 [StageMetrics.imeStageInset]
///   与 [StageMetrics.safeTopStage]/[StageMetrics.safeBottomStage] 供新增纵向容器使用；
/// * 竖屏的可用高度由调用方在**进入 compute 之前**按 T02
///   docs/flutter-migration/contracts/layout.md:287/:299 扣好 safe.top/safe.bottom
///   （layoutH），或用 [StageInputs.portraitFromWindow] 做这一步；
/// * 横屏沿用 Qt 全窗口高（Qt/qml/Main.qml:32），不做安全区扣减。
/// 本类只承载数值，不隐式改几何，避免同一个 inset 被扣两次。
class StageInsets {
  const StageInsets({
    this.top = 0,
    this.bottom = 0,
    this.left = 0,
    this.right = 0,
    this.imeBottom = 0,
  });

  static const StageInsets zero = StageInsets();

  final double top;
  final double bottom;
  final double left;
  final double right;

  /// IME 遮挡高度（逻辑像素），对应 MediaQuery.viewInsets.bottom。
  final double imeBottom;

  double get horizontal => left + right;
  double get vertical => top + bottom;

  @override
  bool operator ==(Object other) =>
      other is StageInsets &&
      other.top == top &&
      other.bottom == bottom &&
      other.left == left &&
      other.right == right &&
      other.imeBottom == imeBottom;

  @override
  int get hashCode => Object.hash(top, bottom, left, right, imeBottom);

  @override
  String toString() =>
      'StageInsets(top: ' + top.toString() + ', bottom: ' + bottom.toString() +
      ', left: ' + left.toString() + ', right: ' + right.toString() +
      ', imeBottom: ' + imeBottom.toString() + ')';
}

/// stage 重算的全部输入：媒体查询里真正参与几何的那几项。
class StageInputs {
  const StageInputs({
    required this.logicalWidth,
    required this.logicalHeight,
    this.devicePixelRatio = 1,
    this.insets = StageInsets.zero,
  });

  /// 竖屏场景的可用窗口高工厂（T02
  /// docs/flutter-migration/contracts/layout.md:287/:299）。
  ///
  /// 只用于竖屏：layoutH = windowHeight - safe.top - safe.bottom，再交给
  /// [StageMetrics.compute]。横屏必须继续传完整窗口高（Qt/qml/Main.qml:32 用全高），
  /// 不要把本工厂的产物拿去算横屏，否则会把 Qt 的 1080 高基线缩掉安全区。
  ///
  /// 本工厂只做 §6 的减法，不碰 IME（plan:364：IME 不缩放 stage）。
  factory StageInputs.portraitFromWindow({
    required double logicalWidth,
    required double windowHeight,
    StageInsets insets = StageInsets.zero,
    double devicePixelRatio = 1,
  }) {
    final double available = math.max(0.0, windowHeight - insets.top - insets.bottom);
    return StageInputs(
      logicalWidth: logicalWidth,
      logicalHeight: available,
      devicePixelRatio: devicePixelRatio,
      insets: insets,
    );
  }

  /// MediaQuery.size.width（逻辑像素）。
  final double logicalWidth;

  /// 参与舞台几何的高度（逻辑像素）。
  ///
  /// 横屏传 MediaQuery.size.height（Qt 全窗口高）；竖屏传 T02
  /// docs/flutter-migration/contracts/layout.md:287 定义的 layoutH —— 已扣
  /// safe.top/safe.bottom。可直接用 [StageInputs.portraitFromWindow] 生成。
  final double logicalHeight;

  /// MediaQuery.devicePixelRatio。
  final double devicePixelRatio;

  final StageInsets insets;
}

/// 一次方向/尺寸变化后的舞台度量。绘制与命中都读这一份，跨帧不得复用
/// （Qt 每帧重建命中表：Qt/src/NativeHud.cpp:224-256）。
class StageMetrics {
  const StageMetrics({
    required this.orientation,
    required this.stageScale,
    required this.stageWidth,
    required this.stageHeight,
    required this.logicalWidth,
    required this.logicalHeight,
    required this.devicePixelRatio,
    required this.insets,
    required this.cameraCompact,
  });

  /// 唯一 stage 重算入口（旋转/窗口变化后只调它）。
  ///
  /// * 横屏沿用 Qt：舞台高恒 1080，stageScale = logicalHeight / 1080，
  ///   stageWidth = logicalWidth / stageScale（Qt/qml/Main.qml:32-33；
  ///   Qt/src/Engine.cpp:1353 用物理像素算同一比值）。
  /// * 竖屏是新语义：舞台宽恒 1080，stageScale = logicalWidth / 1080，
  ///   stageHeight = logicalHeight / stageScale（plan:362 Portrait-W 几何；
  ///   T43 portrait_bands.dart 同式；T02 docs/flutter-migration/contracts/layout.md:290-292
  ///   同式）。三种候选样板的**舞台盒**一致，差别只在盒内分带，故此处不构成样板裁决。
  /// * 竖屏的 logicalHeight 必须是 §6 的 layoutH（已扣 safe.top/safe.bottom，
  ///   layout.md:287/:299），用 [StageInputs.portraitFromWindow] 生成；本函数不再扣一次。
  ///   横屏 logicalHeight 保持 Qt 全窗口高（Qt/qml/Main.qml:32）。
  /// * dpr 不参与换算：物理像素下的 stageScale 恰好是逻辑值乘 dpr，比值不变；
  ///   dpr 只用于 [cameraCompact] 的物理像素阈值。
  /// * IME 不参与换算（plan:364「IME 不缩放 stage」）；安全区扣减已在输入层完成，
  ///   本函数不接收 MediaQuery 原始全高再自行猜测扣减。
  factory StageMetrics.compute(StageInputs inputs) {
    final double width = inputs.logicalWidth;
    final double height = inputs.logicalHeight;
    if (!(width > 0) || !(height > 0)) {
      return StageMetrics(
        orientation: OrientationKind.landscape,
        stageScale: 0,
        stageWidth: qtStageWidthFallbackUnits,
        stageHeight: qtStageHeightUnits,
        logicalWidth: math.max(0.0, width),
        logicalHeight: math.max(0.0, height),
        devicePixelRatio: inputs.devicePixelRatio,
        insets: inputs.insets,
        cameraCompact: false,
      );
    }
    final double aspect = width / height;
    final bool portrait = aspect < qtPortraitAspectThreshold;
    final double scale = portrait ? width / portraitStageWidthUnits : height / qtStageHeightUnits;
    final double stageWidth = portrait ? portraitStageWidthUnits : width / scale;
    final double stageHeight = portrait ? height / scale : qtStageHeightUnits;
    return StageMetrics(
      orientation: portrait ? OrientationKind.portrait : OrientationKind.landscape,
      stageScale: scale,
      stageWidth: stageWidth,
      stageHeight: stageHeight,
      logicalWidth: width,
      logicalHeight: height,
      devicePixelRatio: inputs.devicePixelRatio,
      insets: inputs.insets,
      cameraCompact: !portrait && width * inputs.devicePixelRatio < qtCompactPhysicalWidthThreshold,
    );
  }

  final OrientationKind orientation;

  /// 逻辑像素 / 舞台单位。
  final double stageScale;

  /// 舞台单位。
  final double stageWidth;

  /// 舞台单位。
  final double stageHeight;

  final double logicalWidth;
  final double logicalHeight;
  final double devicePixelRatio;
  final StageInsets insets;

  /// 横屏内的紧凑相机分支（Qt/src/NativeSceneCamera.cpp:57）。
  /// 比较的是物理宽，与 Qt 的 m_width 同域。
  final bool cameraCompact;

  bool get isPortrait => orientation == OrientationKind.portrait;
  bool get isLandscape => orientation == OrientationKind.landscape;

  /// 物理像素 / 舞台单位（Qt 的 m_width/m_height 就是这一域）。
  double get physicalStageScale => stageScale * devicePixelRatio;

  /// 逻辑像素 -> 舞台单位。stageScale 为 0（退化窗口）时返回 0，避免 inf。
  double stageOf(double logical) => stageScale > 0 ? logical / stageScale : 0;

  /// 舞台单位 -> 逻辑像素。
  double logicalOf(double stage) => stage * stageScale;

  double get imeStageInset => stageOf(insets.imeBottom);
  double get safeTopStage => stageOf(insets.top);
  double get safeBottomStage => stageOf(insets.bottom);

  /// 只比较「stage 几何」是否真的变了：方向/缩放/宽/高。
  /// 旋转后调用方用它决定是否重排，而不是拿它去重启引擎（plan:369）。
  bool geometryEquals(StageMetrics other, {double tolerance = stageGeometryTolerance}) =>
      orientation == other.orientation &&
      (stageScale - other.stageScale).abs() <= tolerance &&
      (stageWidth - other.stageWidth).abs() <= tolerance &&
      (stageHeight - other.stageHeight).abs() <= tolerance;

  @override
  bool operator ==(Object other) =>
      other is StageMetrics &&
      other.orientation == orientation &&
      other.stageScale == stageScale &&
      other.stageWidth == stageWidth &&
      other.stageHeight == stageHeight &&
      other.logicalWidth == logicalWidth &&
      other.logicalHeight == logicalHeight &&
      other.devicePixelRatio == devicePixelRatio &&
      other.insets == insets &&
      other.cameraCompact == cameraCompact;

  @override
  int get hashCode => Object.hash(orientation, stageScale, stageWidth, stageHeight, logicalWidth,
      logicalHeight, devicePixelRatio, insets, cameraCompact);

  @override
  String toString() => 'StageMetrics(' + orientation.name + ', scale: ' + stageScale.toString() +
      ', stage: ' + stageWidth.toString() + 'x' + stageHeight.toString() + ')';
}

/// 「stage 重算入口」的具名别名：MediaQuery 变化后唯一该调的函数。
StageMetrics recomputeStage(StageInputs inputs) => StageMetrics.compute(inputs);

// ---------------------------------------------------------------------------
// 相对滚动锚（item key + 相对偏移，绝不放绝对像素）
// ---------------------------------------------------------------------------

/// 一个滚动区的行域度量。
class ScrollExtent {
  const ScrollExtent({
    required this.itemExtent,
    required this.itemCount,
    required this.viewportExtent,
  });

  /// 单行/单项的可视尺寸（舞台单位或逻辑像素，调用方保持一致）。
  final double itemExtent;

  final int itemCount;

  /// 视口尺寸，同一单位。
  final double viewportExtent;

  /// Qt/src/HudScroll.h:13-15。
  double get maximum => math.max(0.0, itemCount * itemExtent - viewportExtent);

  @override
  bool operator ==(Object other) =>
      other is ScrollExtent &&
      other.itemExtent == itemExtent &&
      other.itemCount == itemCount &&
      other.viewportExtent == viewportExtent;

  @override
  int get hashCode => Object.hash(itemExtent, itemCount, viewportExtent);

  @override
  String toString() =>
      'ScrollExtent(itemExtent: ' + itemExtent.toString() + ', count: ' + itemCount.toString() +
      ', viewport: ' + viewportExtent.toString() + ')';
}

/// 滚动锚：锚定 item 的 key + 该项内部已越过的比例。
///
/// plan:371 要求「item key + **相对**滚动偏移（不是绝对 offset）」；Qt 侧持久化的是
/// 行域整数（Qt/src/MusicSession.cpp:229-231 listOffset/trackOffset/bodyOffset，
/// 恢复时 nonnegative 夹取 :254-256；行域证据 Qt/src/NativeHudController.cpp:301、
/// Qt/src/NativeHudInput.cpp:57 都是「行号 + 行数」运算），行内细粒度不在 Qt 状态里 ——
/// 故这里补的是行内比例（plan:371），方向换算完全落在行域，跨旋转只需换 itemExtent。
///
/// 夹取上界：Qt 恢复只做 nonnegative（:254-256）；本实现的 capture/[pixelOffsetFor] 额外
/// 夹到 [0, extent.maximum]，与 HudScroll::clampOffset（Qt/src/HudScroll.h:17-19）同向，
/// 但量纲不同：本实现是像素域，maximum = count*itemExtent - viewportExtent，等于最后
/// 一页对齐；Qt queueOffset 是行域，运行时夹 [0, count-1]（Qt/src/PlaybackQueueCard.cpp:6-8
/// 的 maximumOffset；Qt/src/NativeHudPlayer.cpp:47,74-76 按首可见行使用），允许过滚。
/// 集成换算 row = pixel / rowHeight；Qt 的 count-1 过滚位在像素模型里折叠到最后一页上界。
class ScrollAnchor {
  const ScrollAnchor({
    required this.itemKey,
    required this.itemIndex,
    required this.withinItem,
  });

  /// 零值锚：列表顶部。用于「还没滚动过」的初始态。
  static const ScrollAnchor top = ScrollAnchor(itemKey: '', itemIndex: 0, withinItem: 0);

  /// 锚定项的业务 key（列表项身份，不是下标；下标会随数据变化）。
  final String itemKey;

  /// 锚定项在列表中的下标（行域）。
  final int itemIndex;

  /// 锚定项内部已越过的比例，∈ [0,1]。1 等价于「下一项顶部对齐」。
  final double withinItem;

  /// 从一次真实滚动位置生成锚。pixelOffset 只在这里出现一次，随后即被消去。
  factory ScrollAnchor.capture({
    required String itemKey,
    required int itemIndex,
    required double pixelOffset,
    required double itemExtent,
    required int itemCount,
    required double viewportExtent,
  }) {
    final int count = math.max(0, itemCount);
    if (count == 0 || itemExtent <= 0) {
      return ScrollAnchor(itemKey: itemKey, itemIndex: 0, withinItem: 0);
    }
    final int index = _clampInt(itemIndex, 0, count - 1);
    final double maximum = math.max(0.0, count * itemExtent - viewportExtent);
    final double offset = _clampDouble(pixelOffset, 0, maximum);
    final double within = _clampDouble((offset - index * itemExtent) / itemExtent, 0, 1);
    return ScrollAnchor(itemKey: itemKey, itemIndex: index, withinItem: within);
  }

  ScrollAnchor sanitized() => ScrollAnchor(
        itemKey: itemKey,
        itemIndex: _nonnegative(itemIndex),
        withinItem: _clampDouble(withinItem, 0, 1),
      );

  /// 在**新的** extent 下解出绝对偏移。旋转只改 itemExtent/viewport，锚不变。
  double pixelOffsetFor(ScrollExtent extent) {
    if (extent.itemCount <= 0 || extent.itemExtent <= 0) {
      return 0;
    }
    final int index = _clampInt(itemIndex, 0, extent.itemCount - 1);
    final double raw = (index + withinItem) * extent.itemExtent;
    return _clampDouble(raw, 0, extent.maximum);
  }

  @override
  bool operator ==(Object other) =>
      other is ScrollAnchor &&
      other.itemKey == itemKey &&
      other.itemIndex == itemIndex &&
      other.withinItem == withinItem;

  @override
  int get hashCode => Object.hash(itemKey, itemIndex, withinItem);

  @override
  String toString() =>
      'ScrollAnchor(' + itemKey + ', index: ' + itemIndex.toString() +
      ', within: ' + withinItem.toString() + ')';
}

/// 一次解析出来的绝对偏移（像素或舞台单位，取决于传入 extent 的单位）。
class ResolvedScrollOffsets {
  const ResolvedScrollOffsets({
    required this.list,
    required this.track,
    required this.body,
    required this.queue,
    required this.settings,
  });

  final double list;
  final double track;
  final double body;
  final double queue;
  final double settings;

  @override
  bool operator ==(Object other) =>
      other is ResolvedScrollOffsets &&
      other.list == list &&
      other.track == track &&
      other.body == body &&
      other.queue == queue &&
      other.settings == settings;

  @override
  int get hashCode => Object.hash(list, track, body, queue, settings);

  @override
  String toString() => 'ResolvedScrollOffsets(list: ' + list.toString() + ', track: ' +
      track.toString() + ', body: ' + body.toString() + ', queue: ' +
      queue.toString() + ', settings: ' + settings.toString() + ')';
}

// ---------------------------------------------------------------------------
// 视图状态中的各个块
// ---------------------------------------------------------------------------

/// 目录栈的一层：字段与夹取逐条对应 Qt MusicDirectory
/// （Qt/src/MusicLibrary.h:12-34）与恢复逻辑（Qt/src/MusicSession.cpp:127-135）。
class DirectoryFrame {
  const DirectoryFrame({
    this.itemKey = '',
    this.cursor = 0,
    this.index = 0,
    this.anchor = 0,
    this.albumCursor = 0,
    this.parentPhysical = 0,
    this.parentLane = 0,
    this.idCount = 0,
    this.songCount = 0,
  });

  /// 目录项身份（Qt 持久化整个 item，这里只留 key；见报告 decisions）。
  final String itemKey;

  /// 分页游标，夹到 [0, idCount]（Qt/src/MusicSession.cpp:127）。
  final int cursor;

  /// 当前项下标，夹到 [0, max(0, songCount-1)]（:128）。
  final int index;

  /// 一屏行锚，夹到 [0,39]（:129）。
  final int anchor;

  /// 专辑列表游标，nonnegative（:134）。
  final int albumCursor;

  /// 返回目录时落点，夹到 [0,39]（:131）。
  final int parentPhysical;

  /// 返回目录时所在 lane，夹到 [0,4]（:132）。
  final int parentLane;

  final int idCount;
  final int songCount;

  /// Qt/src/MusicSession.cpp:130 "folder->page = folder->index / 40 * 40"。
  int get page => index ~/ pageSize * pageSize;

  DirectoryFrame sanitized() {
    final int ids = math.max(0, idCount);
    final int songs = math.max(0, songCount);
    return DirectoryFrame(
      itemKey: itemKey,
      cursor: _clampInt(cursor, 0, ids),
      index: _clampInt(index, 0, math.max(0, songs - 1)),
      anchor: _clampInt(anchor, 0, pageSize - 1),
      albumCursor: _nonnegative(albumCursor),
      parentPhysical: _clampInt(parentPhysical, 0, pageSize - 1),
      parentLane: _clampInt(parentLane, 0, laneCount - 1),
      idCount: ids,
      songCount: songs,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is DirectoryFrame &&
      other.itemKey == itemKey &&
      other.cursor == cursor &&
      other.index == index &&
      other.anchor == anchor &&
      other.albumCursor == albumCursor &&
      other.parentPhysical == parentPhysical &&
      other.parentLane == parentLane &&
      other.idCount == idCount &&
      other.songCount == songCount;

  @override
  int get hashCode => Object.hash(itemKey, cursor, index, anchor, albumCursor, parentPhysical,
      parentLane, idCount, songCount);

  @override
  String toString() => 'DirectoryFrame(' + itemKey + ', cursor: ' + cursor.toString() +
      ', index: ' + index.toString() + ', anchor: ' + anchor.toString() +
      ', albumCursor: ' + albumCursor.toString() + ')';
}

/// 输入框状态：文本、selection、composing、focus（plan:372）。
///
/// composing 对应 QML 的 preeditText（Qt/qml/Overlay.qml:555 用它决定 placeholder），
/// 无 composing 时 start/end 均为 -1。selection 用 base+extent 表达，
/// 与 Flutter TextSelection 同构，且 extent 可负（反向选择）。
class TextInputState {
  const TextInputState({
    this.text = '',
    this.selectionBase = 0,
    this.selectionExtent = 0,
    this.composingStart = -1,
    this.composingEnd = -1,
    this.focused = false,
  });

  final String text;
  final int selectionBase;
  final int selectionExtent;
  final int composingStart;
  final int composingEnd;
  final bool focused;

  int get selectionStart => math.min(selectionBase, selectionBase + selectionExtent);
  int get selectionEnd => math.max(selectionBase, selectionBase + selectionExtent);
  bool get hasComposing => composingStart >= 0 && composingEnd >= 0;

  /// 文本域不变量：范围必须落在 text 内，否则 TextEditingValue 会抛/吞输入。
  /// 这不是新阈值，只是把「下标不超过文本长度」写成结构约束。
  TextInputState sanitized() {
    final int length = text.length;
    final int base = _clampInt(selectionBase, 0, length);
    final int extent = _clampInt(selectionExtent, -base, length - base);
    final bool composing = composingStart >= 0 && composingEnd >= 0;
    final int start = composing ? _clampInt(composingStart, 0, length) : -1;
    final int end = composing ? _clampInt(composingEnd, start, length) : -1;
    return TextInputState(
      text: text,
      selectionBase: base,
      selectionExtent: extent,
      composingStart: start,
      composingEnd: end,
      focused: focused,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is TextInputState &&
      other.text == text &&
      other.selectionBase == selectionBase &&
      other.selectionExtent == selectionExtent &&
      other.composingStart == composingStart &&
      other.composingEnd == composingEnd &&
      other.focused == focused;

  @override
  int get hashCode => Object.hash(text, selectionBase, selectionExtent, composingStart,
      composingEnd, focused);

  @override
  String toString() => 'TextInputState(len: ' + text.length.toString() + ', selection: ' +
      selectionStart.toString() + '..' + selectionEnd.toString() + ', focused: ' +
      focused.toString() + ')';
}

/// 设置页通用文本编辑中的那一行：key + 文本 + 光标（plan:372）。
///
/// Qt 用 editingSettingId 是否为空表示「没有在编辑」（Qt/src/NativeHud.h:103-106
/// 注释「清空 id 即隐藏」），文本经 settingEditText() 回写
/// （Qt/qml/Overlay.qml:591），浮层位置由 Schema 行给出（同文件:566-570）。
class SettingEditState {
  const SettingEditState({
    this.settingKey = '',
    this.text = '',
    this.cursor = 0,
  });

  final String settingKey;
  final String text;
  final int cursor;

  bool get active => settingKey.isNotEmpty;

  SettingEditState sanitized() => SettingEditState(
        settingKey: settingKey,
        text: text,
        cursor: _clampInt(cursor, 0, text.length),
      );

  @override
  bool operator ==(Object other) =>
      other is SettingEditState &&
      other.settingKey == settingKey &&
      other.text == text &&
      other.cursor == cursor;

  @override
  int get hashCode => Object.hash(settingKey, text, cursor);

  @override
  String toString() => 'SettingEditState(' + settingKey + ', textLen: ' + text.length.toString() +
      ', cursor: ' + cursor.toString() + ')';
}

/// modal 名 + 关闭中标志 + 当前动画位置 modalOffset（plan:376）。
///
/// 白名单七项见 [restorableModalNames]（Qt/src/MusicSession.cpp:243）。
/// 旋转路径**保留** closing 与 offset：Qt 运行时只有关闭动画走完才清 modal
/// （Qt/src/NativeHud.cpp:263-265 "if (closing && motion.finished()) { modal.clear();
/// closing = false; }"）；旋转只走 Engine.cpp:841-849 的 scene.resize + wake，没有该复位。
/// Qt/src/MusicSession.cpp:222 的「closing 时写空串」只属于磁盘 sessionState 写盘，
/// 落盘时用 [diskModalName] 显式表达，不能把它套到旋转语义上。
class ModalState {
  const ModalState({
    this.name,
    this.closing = false,
    this.offset = 0,
  });

  static const ModalState none = ModalState();

  final String? name;
  final bool closing;

  /// Qt/src/NativeHud.cpp:205 {"modalOffset", motion.offset}，舞台单位。
  final double offset;

  bool get isOpen => name != null;

  /// 旋转路径的规范化：白名单判定不变；closing 与 offset 原样保留。
  /// 只有「没有弹层 / 空名 / 非白名单」才落 [none]。
  ModalState sanitized() {
    final String? current = name;
    if (current == null || current.isEmpty || !restorableModalNames.contains(current)) {
      return none;
    }
    // offset 是舞台单位（方向无关），也是当前动画位置（plan:376）；closing 只是关闭中
    // 标志。restore 侧必须从 offset 续播、不得从 0 重启；关闭动画的 owner 在 Widget
    // 树之外（plan:369），列为 A2/A3 集成项，集成时由该 owner 消费本 offset 作为起点。
    // 两者都原样保留。
    return ModalState(name: current, closing: closing, offset: offset);
  }

  /// 磁盘 sessionState 的 modal 名，逐字对应 Qt/src/MusicSession.cpp:222
  /// "hud.closing ? QString() : hud.modal"。只允许落盘层调用；旋转用 [sanitized]。
  String get diskModalName => closing ? '' : (name ?? '');

  @override
  bool operator ==(Object other) =>
      other is ModalState && other.name == name && other.closing == closing && other.offset == offset;

  @override
  int get hashCode => Object.hash(name, closing, offset);

  @override
  String toString() =>
      'ModalState(' + (name ?? 'none') + ', closing: ' + closing.toString() +
      ', offset: ' + offset.toString() + ')';
}

/// 滚动数字/滚动曲线的代次标识（plan:376「滚动数字曲线不重启」）。
///
/// 旋转只做 resume：代次原样带走。只有真正的重新启动才允许 [nextGeneration]，
/// 这样「旋转后曲线从头开始」在类型层就写不出来。
class CurveToken {
  const CurveToken({
    this.id = '',
    this.generation = 0,
  });

  static const CurveToken none = CurveToken();

  final String id;
  final int generation;

  bool sameCurveAs(CurveToken other) => id == other.id && generation == other.generation;

  /// 旋转唯一允许的动作：同一曲线、同一代次，返回自身。
  CurveToken resumeAcrossRotation() => this;

  /// 真正的重启；旋转路径禁止调用。
  CurveToken nextGeneration() => CurveToken(id: id, generation: generation + 1);

  @override
  bool operator ==(Object other) =>
      other is CurveToken && other.id == id && other.generation == generation;

  @override
  int get hashCode => Object.hash(id, generation);

  @override
  String toString() => 'CurveToken(' + id + '#' + generation.toString() + ')';
}

// ---------------------------------------------------------------------------
// 总状态 + capture/restore
// ---------------------------------------------------------------------------

/// 必须跨旋转保留的视图状态（plan:371-372、376 的 A1 侧子集）。
///
/// 全部字段方向无关：lane 行号、目录游标、相对锚、文本下标、舞台单位偏移。
class OrientationViewState {
  const OrientationViewState({
    this.currentLane = 0,
    this.laneRowMemory = const <int>[0, 0, 0, 0, 0],
    this.directoryStack = const <DirectoryFrame>[],
    this.listAnchor = ScrollAnchor.top,
    this.trackAnchor = ScrollAnchor.top,
    this.bodyAnchor = ScrollAnchor.top,
    this.queueAnchor = ScrollAnchor.top,
    this.selected = 0,
    this.musicCollection = 1,
    this.settingsScroll = 0,
    this.settingsContentBottom = defaultSettingsContentBottom,
    this.input = const TextInputState(),
    this.settingEdit = const SettingEditState(),
    this.modal = ModalState.none,
    this.curve = CurveToken.none,
  });

  /// 当前 lane，夹到 [0,4]（Qt/src/MusicLibrary.h:167；恢复侧同域校验
  /// Qt/src/MusicSession.cpp:95 "lane < 0 || lane >= 5" 直接拒绝，这里夹取）。
  final int currentLane;

  /// 每个 lane 记住的行 0..7（Qt/src/MusicLibrary.h:149 rowMemory；
  /// 夹取 Qt/src/MusicSession.cpp:111）。
  final List<int> laneRowMemory;

  /// 目录栈，栈顶在末尾（Qt 的 parent 链，Qt/src/MusicLibrary.h:12-34）。
  final List<DirectoryFrame> directoryStack;

  /// 列表滚动锚：Qt listOffset 的行域等价物（Qt/src/MusicSession.cpp:229）。
  final ScrollAnchor listAnchor;

  /// 单曲列表锚：Qt trackOffset（:230）。
  final ScrollAnchor trackAnchor;

  /// 详情正文锚：Qt bodyOffset（:231）。
  final ScrollAnchor bodyAnchor;

  /// 队列弹层锚：Qt queueOffset（Qt/src/NativeHud.h:113；写出
  /// Qt/src/MusicSession.cpp:223，恢复 :246 nonnegative；运行时上界
  /// Qt/src/NativeHudPlayer.cpp:47）。plan:374 要求队列跨旋转不丢。
  final ScrollAnchor queueAnchor;

  /// 3D 场景选中卡，夹到 [0,39]（Qt/src/MusicSession.cpp:260）。
  final int selected;

  /// 音乐库集合，夹到 [1,4]（Qt/src/MusicSession.cpp:257
  /// "std::clamp(view[\"musicCollection\"].toInt(1), 1, 4)"）。
  final int musicCollection;

  /// 设置页滚动，夹到 [0, settingsScrollMaximum]（Qt/src/MusicSession.cpp:247）。
  final double settingsScroll;

  /// 设置内容底边（舞台单位），决定上面那个上限；Qt/src/NativeHud.h:117。
  final double settingsContentBottom;

  final TextInputState input;
  final SettingEditState settingEdit;
  final ModalState modal;
  final CurveToken curve;

  /// Qt/src/NativeHud.h:132-135。
  double get settingsScrollMaximum => settingsScrollMaximumFor(settingsContentBottom);

  /// 规范化：夹取 + 白名单 + 栈截断。capture 与 restore 都过这一关。
  OrientationViewState sanitized() {
    final List<int> memory = <int>[];
    for (int lane = 0; lane < laneCount; lane++) {
      final int raw = lane < laneRowMemory.length ? laneRowMemory[lane] : 0;
      memory.add(_clampInt(raw, 0, rowsPerPage - 1));
    }
    // Qt 在 >64 层时整份拒绝恢复（Qt/src/MusicSession.cpp:100）。旋转不该把会话判废，
    // 因此这里保留最深的 64 层（栈顶在末尾）。
    final int keep = math.min(directoryStack.length, directoryStackLimit);
    final List<DirectoryFrame> stack = <DirectoryFrame>[];
    for (int i = directoryStack.length - keep; i < directoryStack.length; i++) {
      stack.add(directoryStack[i].sanitized());
    }
    return OrientationViewState(
      currentLane: _clampInt(currentLane, 0, laneCount - 1),
      laneRowMemory: List<int>.unmodifiable(memory),
      directoryStack: List<DirectoryFrame>.unmodifiable(stack),
      listAnchor: listAnchor.sanitized(),
      trackAnchor: trackAnchor.sanitized(),
      bodyAnchor: bodyAnchor.sanitized(),
      queueAnchor: queueAnchor.sanitized(),
      selected: _clampInt(selected, 0, pageSize - 1),
      musicCollection: _clampInt(musicCollection, 1, 4),
      settingsScroll: _clampDouble(settingsScroll, 0, settingsScrollMaximum),
      settingsContentBottom: settingsContentBottom,
      input: input.sanitized(),
      settingEdit: settingEdit.sanitized(),
      modal: modal.sanitized(),
      curve: curve.resumeAcrossRotation(),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is OrientationViewState &&
      other.currentLane == currentLane &&
      _listEquals(other.laneRowMemory, laneRowMemory) &&
      _listEquals(other.directoryStack, directoryStack) &&
      other.listAnchor == listAnchor &&
      other.trackAnchor == trackAnchor &&
      other.bodyAnchor == bodyAnchor &&
      other.queueAnchor == queueAnchor &&
      other.selected == selected &&
      other.musicCollection == musicCollection &&
      other.settingsScroll == settingsScroll &&
      other.settingsContentBottom == settingsContentBottom &&
      other.input == input &&
      other.settingEdit == settingEdit &&
      other.modal == modal &&
      other.curve == curve;

  @override
  int get hashCode => Object.hash(
        currentLane,
        Object.hashAll(laneRowMemory),
        Object.hashAll(directoryStack),
        listAnchor,
        trackAnchor,
        bodyAnchor,
        queueAnchor,
        selected,
        musicCollection,
        settingsScroll,
        settingsContentBottom,
        input,
        settingEdit,
        modal,
        curve,
      );

  @override
  String toString() => 'OrientationViewState(lane: ' + currentLane.toString() + ', rows: ' +
      laneRowMemory.toString() + ', stack: ' + directoryStack.length.toString() + ', list: ' +
      listAnchor.toString() + ', track: ' + trackAnchor.toString() + ', body: ' +
      bodyAnchor.toString() + ', queue: ' + queueAnchor.toString() + ', modal: ' +
      modal.toString() + ', curve: ' + curve.toString() + ')';
}

/// capture 的产物：规范化后的状态 + 当时的 stage 签名。
///
/// 签名的用途只有一个：诊断/断言「确实跨了方向」，不参与还原计算 ——
/// 状态本来就是方向无关的，所以还原不需要旧像素。
class OrientationSnapshot {
  const OrientationSnapshot({
    required this.state,
    required this.sourceOrientation,
    required this.sourceStageScale,
    required this.sourceStageWidth,
    required this.sourceStageHeight,
  });

  final OrientationViewState state;
  final OrientationKind sourceOrientation;
  final double sourceStageScale;
  final double sourceStageWidth;
  final double sourceStageHeight;

  bool crossesOrientation(StageMetrics metrics) => metrics.orientation != sourceOrientation;

  /// 新舞台缩放 / 旧舞台缩放；旧缩放为 0（退化窗口）时返回 0。
  double rescaleFactor(StageMetrics metrics) =>
      sourceStageScale > 0 ? metrics.stageScale / sourceStageScale : 0;

  @override
  bool operator ==(Object other) =>
      other is OrientationSnapshot &&
      other.state == state &&
      other.sourceOrientation == sourceOrientation &&
      other.sourceStageScale == sourceStageScale &&
      other.sourceStageWidth == sourceStageWidth &&
      other.sourceStageHeight == sourceStageHeight;

  @override
  int get hashCode => Object.hash(state, sourceOrientation, sourceStageScale, sourceStageWidth,
      sourceStageHeight);

  @override
  String toString() => 'OrientationSnapshot(' + sourceOrientation.name + ', scale: ' +
      sourceStageScale.toString() + ')';
}

/// 旋转前捕获：夹取 + 白名单过滤 + 栈截断一次做完，产出方向无关的快照（plan:369）。
OrientationSnapshot captureOrientationState(OrientationViewState state, StageMetrics metrics) =>
    OrientationSnapshot(
      state: state.sanitized(),
      sourceOrientation: metrics.orientation,
      sourceStageScale: metrics.stageScale,
      sourceStageWidth: metrics.stageWidth,
      sourceStageHeight: metrics.stageHeight,
    );

/// 旋转后还原：返回方向无关状态；stage 尚不可度量的那一帧沿用此前有效状态。
///
/// 退化尺寸的语义对齐 Qt/src/Engine.cpp:841-849：`Engine::resize` 在
/// `height <= 0`（或尺寸未变）时直接 `return`，静默保留上一帧的
/// `m_width`/`m_height`，从不抛错。Flutter 侧同理 —— 首帧、最小化、旋转交接都
/// 可能出现 logicalWidth/logicalHeight 为 0 的一帧，抛错只会把「本帧没有几何」
/// 变成崩溃/红屏，而不是让上一帧继续显示。
///
/// 因此 `metrics.stageScale <= 0` 不是错误，而是「本帧不应用新舞台」：返回值仍是
/// [snapshot.state] 的净化副本，即此前已经生效的方向无关状态。调用方若需要区分
/// 本帧是否真的应用了舞台，读 `metrics.stageScale > 0` 即可；公开签名保持
/// [OrientationViewState]，现有调用点不需要改动，也不新增「抛错即期望」的分支。
///
/// 为什么这里不按 metrics 改任何数值：状态里的每个量都在行域/文本域/舞台单位，
/// 舞台单位在横竖屏都由同一套 1080 基准定义（Qt/qml/Main.qml:32、
/// T43 portrait_bands.dart:32），所以没有「旧像素 -> 新像素」这一步。
/// 绝对偏移由 [resolveScrollOffsets] 在需要绘制时按新 extent 现算（plan:371）。
OrientationViewState restoreOrientationState(OrientationSnapshot snapshot, StageMetrics metrics) {
  // 退化帧不抛错：Engine::resize 静默保留上一有效尺寸（Qt/src/Engine.cpp:841-843），
  // 这里对应地静默保留上一有效状态。StageMetrics.compute 对不可度量输入给出
  // stageScale == 0（见本文件 :297-309），上层据此判断本帧未应用舞台；
  // 状态本身方向无关，故可度量帧与退化帧返回同一份净化状态。
  return snapshot.state.sanitized();
}

/// 按新方向的 extent 解出列表/单曲/详情/队列四个滚动区的绝对偏移（唯一的像素出口）。
ResolvedScrollOffsets resolveScrollOffsets(
  OrientationViewState state, {
  required ScrollExtent list,
  required ScrollExtent track,
  required ScrollExtent body,
  required ScrollExtent queue,
}) {
  final OrientationViewState safe = state.sanitized();
  return ResolvedScrollOffsets(
    list: safe.listAnchor.pixelOffsetFor(list),
    track: safe.trackAnchor.pixelOffsetFor(track),
    body: safe.bodyAnchor.pixelOffsetFor(body),
    queue: safe.queueAnchor.pixelOffsetFor(queue),
    settings: safe.settingsScroll,
  );
}

// ---------------------------------------------------------------------------
// 比较工具
// ---------------------------------------------------------------------------

bool _listEquals<T>(List<T> a, List<T> b) {
  if (identical(a, b)) {
    return true;
  }
  if (a.length != b.length) {
    return false;
  }
  for (int i = 0; i < a.length; i++) {
    if (a[i] != b[i]) {
      return false;
    }
  }
  return true;
}
