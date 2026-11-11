/// 竖屏舞台几何与 Qt 舞台常量（只依赖 dart:math 与 Flutter foundation）。
///
/// 这一份度量是绘制与命中的唯一来源：尺寸变化后必须整份重算，
/// 禁止跨帧复用上一帧的命中矩形（Qt 每帧 NativeHud::draw 都清表重建，
/// Qt/src/NativeHud.cpp:224-256）。
///
/// 证据约束（逐条可查 Qt 源码）：
/// * 竖屏舞台宽恒 1080 舞台单位 —— 依据 T02
///   docs/flutter-migration/contracts/layout.md §6（portraitStageWidth = 1080），
///   不是 Qt 横屏常量：Qt 的不变量是舞台**高** 1080（Qt/qml/Main.qml:32
///   stageScale = height / 1080），舞台宽 = width / stageScale 随窗口变化
///   （Qt/qml/Main.qml:33，真机横屏 1728）；绘制从左上方缩放
///   （Qt/qml/Overlay.qml:179-184）。
/// * 横屏 stageScale 只由逻辑视口高度决定（Qt/qml/Main.qml:32），Qt 不做任何 inset
///   处理，所以竖屏也不允许用 MediaQuery.viewInsets 去手改 stageScale。
/// * 底栏高 96 / 内容裁剪底 984 —— Qt/src/PlayerBar.h:42、Qt/src/NativeHud.cpp:310-327。
/// * 触摸加宽只发生在触摸层：Android +16 四边（Qt/qml/Overlay.qml:38-43），
///   进度条与音量只做垂直加宽（Qt/qml/Overlay.qml:485-508）。
///
/// 本阶段不裁决 W / Band / Hybrid 谁是样板，也不裁决 bottom sheet / 48dp / 52%：
/// 三个候选都保留为参数，越界与退化情况写进 PortraitBands.degeneracies 显式暴露，
/// 不做静默夹取，也不伪造 golden。
library;

import 'dart:math' as math;

import 'package:flutter/foundation.dart' show FlutterError;

/// 竖屏舞台宽恒定值（舞台单位）。
///
/// 依据 T02 docs/flutter-migration/contracts/layout.md §6 portraitStageWidth = 1080。
/// Qt 侧没有这个常量：Qt 的不变量是舞台高 1080（Qt/qml/Main.qml:32），
/// 舞台宽 = width / stageScale 随窗口变化（Qt/qml/Main.qml:33，真机横屏 1728）。
const double portraitStageWidthConstant = 1080;

/// 横屏舞台高恒定值（舞台单位）。Qt/qml/Main.qml:32。
const double qtStageHeightLandscape = 1080;

/// 几何浮点比较容差。
const double qtGeometryTolerance = 1e-6;

/// 竖屏三种可实施候选；本阶段不裁决赢家。
enum PortraitBandMode { w, band, hybrid }

/// IME 出现时的两种策略；本阶段不裁决赢家。
enum PortraitImePolicy { compress, shiftUp }

/// 模态框分支，与 Qt NativeHud::modalBounds（Qt/src/NativeHud.cpp:140-159）一一对应。
/// Qt 的 default 分支在这里叫 PortraitModalKind.standard（default 是 Dart 关键字）。
enum PortraitModalKind { standard, search, detailSort, lyricsSource, lyricsOffset }

/// 四边 inset，单位由调用方决定（舞台单位或逻辑像素）。
class PortraitInsets {
  const PortraitInsets({this.top = 0, this.bottom = 0, this.left = 0, this.right = 0});

  final double top;
  final double bottom;
  final double left;
  final double right;

  static const PortraitInsets zero = PortraitInsets();

  Map<String, Object?> toJson() => <String, Object?>{
        'top': top,
        'bottom': bottom,
        'left': left,
        'right': right,
      };

  factory PortraitInsets.fromJson(Map<String, Object?> json) => PortraitInsets(
        top: decodeNumber(json['top']),
        bottom: decodeNumber(json['bottom']),
        left: decodeNumber(json['left']),
        right: decodeNumber(json['right']),
      );

  @override
  bool operator ==(Object other) =>
      other is PortraitInsets &&
      other.top == top &&
      other.bottom == bottom &&
      other.left == left &&
      other.right == right;

  @override
  int get hashCode => Object.hash(top, bottom, left, right);

  @override
  String toString() => 'PortraitInsets(top: $top, bottom: $bottom, left: $left, right: $right)';
}

/// 把 fixture 里的数字（int 或 String）读成 double。
double decodeNumber(Object? value) {
  if (value is num) {
    return value.toDouble();
  }
  if (value is String) {
    final double? parsed = double.tryParse(value);
    if (parsed != null) {
      return parsed;
    }
  }
  throw ArgumentError('expected a number, got ' + value.toString());
}

/// 舞台坐标系里的轴对齐矩形。
class StageRect {
  const StageRect(this.x, this.y, this.width, this.height);

  final double x;
  final double y;
  final double width;
  final double height;

  double get right => x + width;
  double get bottom => y + height;

  bool isPositive() => width > 0 && height > 0;

  bool contains(double px, double py, {double epsilon = 0}) =>
      px >= x - epsilon && px <= right + epsilon && py >= y - epsilon && py <= bottom + epsilon;

  /// 本矩形是否被 other 完整包含；容差必须由调用方显式给出。
  bool isWithin(StageRect other, {double epsilon = 0}) =>
      x >= other.x - epsilon &&
      y >= other.y - epsilon &&
      right <= other.right + epsilon &&
      bottom <= other.bottom + epsilon;

  /// 四边同时外扩（Qt 触摸层 Qt/qml/Overlay.qml:38-43）。
  StageRect expand(double pad) => StageRect(x - pad, y - pad, width + pad * 2, height + pad * 2);

  /// 只做垂直外扩，保住 x/width，从而保住进度条与音量的比例
  /// （Qt/qml/Overlay.qml:485-508）。
  StageRect expandVertical(double pad) => StageRect(x, y - pad, width, height + pad * 2);

  StageRect shiftY(double dy) => StageRect(x, y + dy, width, height);

  Map<String, Object?> toJson() => <String, Object?>{
        'x': x,
        'y': y,
        'width': width,
        'height': height,
      };

  factory StageRect.fromJson(Map<String, Object?> json) => StageRect(
        decodeNumber(json['x']),
        decodeNumber(json['y']),
        decodeNumber(json['width']),
        decodeNumber(json['height']),
      );

  @override
  bool operator ==(Object other) =>
      other is StageRect && other.x == x && other.y == y && other.width == width && other.height == height;

  @override
  int get hashCode => Object.hash(x, y, width, height);

  @override
  String toString() => 'StageRect($x, $y, $width, $height)';
}

/// 计算竖屏几何的输入。
///
/// layoutWidth/layoutHeight 是 LayoutBuilder 给出的逻辑可用窗口，**未**扣除安全区；
/// safe 是 MediaQuery.padding（逻辑像素，进入公式前统一除以 stageScale）。
/// imeBottom 只为源码兼容保留：清单是 adjustResize，几何计算**不读取**它；
/// 只有未来改 adjustNothing 时才允许把它作为输入去压容器。
///
/// 唯一读法（DEDUP-19/20）：
/// * stageScale = layoutWidth / 1080，只由窗口宽决定；
/// * stageHeight = (layoutHeight - safe.top - safe.bottom) / stageScale，
///   上下安全区在舞台高度里只扣这一次；
/// * containerTop = safe.top / stageScale 是舞台在窗口中的原点，safe.top
///   只在这里第二次出现（作为原点偏移），**不再**进入 content；
/// * content 全部是 stage 本地坐标：W=(contentX,0,...,stageHeight-96)、
///   Hybrid=(contentX,96,...,stageHeight-192)、Band=(contentX,0,...,stageHeight)；
/// * 清单保持 adjustResize：键盘出现时平台已经缩小 layoutHeight，
///   所以几何计算**不读** imeBottom（imeStage 恒 0），绝不二次扣减。
///
/// 1080x2400 既可以读作逻辑窗口（本实现的默认读法，stageScale = 1.0），
/// 也可以读作某 density 下的物理像素（T02 草案的读法，density 420 时
/// stageScale = 0.380952）。两种读法都未被裁决；实现只认传入的数值，不做 density 猜测。
class PortraitInputs {
  const PortraitInputs({
    required this.layoutWidth,
    required this.layoutHeight,
    this.safe = PortraitInsets.zero,
    this.imeBottom = 0,
    this.android = false,
  });

  final double layoutWidth;
  final double layoutHeight;
  final PortraitInsets safe;
  final double imeBottom;

  /// 平台门：决定触摸层加宽，不参与舞台与内容几何。
  /// Qt 侧同一判据：Qt/qml/Overlay.qml:33
  /// readonly property bool android: Qt.platform.os === "android"；
  /// 加宽量 Qt/qml/Overlay.qml:38 android ? 16 : 0；
  /// Flutter 调用侧用 defaultTargetPlatform（lib/ui/layout/portrait_stage.dart:63）。
  final bool android;
}

/// Qt 侧栏布局结果（Qt/src/NativeHud.cpp:160-166）。
class QtContainerLayout {
  const QtContainerLayout({required this.sidebar, required this.x, required this.width});

  final double sidebar;
  final double x;
  final double width;
}

/// 一次算出的竖屏度量集合。
class PortraitBands {
  PortraitBands({
    required this.mode,
    required this.imePolicy,
    required this.stageScale,
    required this.stageWidth,
    required this.stageHeight,
    required this.containerTop,
    required this.imeStage,
    required this.inputShiftStage,
    required this.contentX,
    required this.contentWidth,
    required this.content,
    required this.playerBar,
    required this.bands,
    required this.bandCount,
    required this.bandHeight,
    required this.bandRatio,
    required this.touchPadding,
    required this.degeneracies,
    required this.notes,
  });

  final PortraitBandMode mode;
  final PortraitImePolicy imePolicy;

  /// 逻辑像素到舞台单位的缩放；竖屏只由逻辑窗口宽决定。
  final double stageScale;

  /// 恒定 1080。
  final double stageWidth;

  /// (逻辑窗口高 - safe.top - safe.bottom) / stageScale。
  ///
  /// 安全区在舞台高度里只扣这一次；playerBar 因此整体抬到手势区之上。
  final double stageHeight;

  /// 舞台在窗口中的原点（stage 单位）：safe.top / stageScale。
  ///
  /// widget 层把它乘以 stageScale 作为 Padding.top，因此舞台缩放后的
  /// 顶边落在逻辑窗口的 safe.top，底边落在 layoutHeight - safe.bottom。
  final double containerTop;

  /// IME 高度在舞台单位下的值。
  ///
  /// 清单保持 adjustResize，平台已缩小窗口；DEDUP-20 之后本字段恒为 0，
  /// 仅为旧调用方的源码兼容保留，几何计算不得再读 viewInsets。
  final double imeStage;

  /// 输入框在舞台单位下需要上移的量。
  ///
  /// adjustResize 下恒为 0（平台负责让出键盘空间），保留字段仅为源码兼容。
  final double inputShiftStage;

  final double contentX;
  final double contentWidth;

  /// 内容可用区，stage 本地坐标。
  ///
  /// 安全区只在 stageHeight 与 containerTop 出现，这里不再扣
  /// safe.top/safe.bottom；adjustResize 下 IME 项恒 0，不参与扣减。
  final StageRect content;

  /// 底栏。W/Band/Hybrid 三种候选对它的定位不同，都算出来、都不冻结。
  final StageRect playerBar;

  /// 该候选的分带结果。
  final List<StageRect> bands;

  final int bandCount;

  /// 整带高度常量 1080 舞台单位（Qt 横屏不变量）；只有 Band 候选按它堆叠。
  /// W/Hybrid 的 bands 不使用这个值，读 bands 本身。
  final double bandHeight;

  /// 未取整的分带比值，与 bandCount 同时暴露，避免 epsilon 守卫掩盖真实数值。
  final double bandRatio;

  /// 本次输入的平台触摸加宽：Android 16，桌面/iOS 0（Qt/qml/Overlay.qml:38）。
  /// 命中层据此做垂直加宽，绘制层永不使用。
  final double touchPadding;

  /// 进度条触摸高（按本次输入的平台）：Android 50，桌面/iOS 18。
  double get seekTouchHeight => QtStageGeometry.seekHeight + touchPadding * 2;

  /// 音量触摸高（按本次输入的平台）：Android 60，桌面/iOS 28。
  double get volumeTouchHeight => QtStageGeometry.volumeHeight + touchPadding * 2;

  /// 退化与越界清单；非空即 isDegenerate。
  final List<String> degeneracies;

  /// 中性说明（不是错误）。
  final List<String> notes;

  double get contentHeight => content.height;
  double get contentTop => content.y;
  double get contentBottom => content.bottom;

  /// 分带内容的总高：从第一带顶到最后一带底（舞台单位）。
  ///
  /// Band 候选的带高恒为 1080，1080x2400 时三带总高 3240；
  /// 舞台本身只有 2400，所以这里会如实返回 3240，不做静默截断。
  double get bandsContentHeight => bands.isEmpty ? 0.0 : bands.last.bottom - bands.first.y;

  /// 分带视口高：就是舞台高。W/Hybrid 的分带通常恰好等于它。
  double get bandsViewportHeight => stageHeight;

  /// 分带溢出量；0 表示当前候选的全部带都能在舞台内完整看到。
  double get bandsOverflow => math.max(0.0, bandsContentHeight - bandsViewportHeight);

  /// 本次分带的视口几何；调用方据此决定滚动或拒绝不安全裁切。
  PortraitBandViewport get bandViewport => PortraitBandViewport.forBands(this);

  /// IME 实际吃掉的高度。
  ///
  /// adjustResize 下恒为 0：键盘空间由平台缩窗口完成，候选不得再扣一次。
  double get imeConsumedStage => 0.0;

  bool get isDegenerate => degeneracies.isNotEmpty;

  Map<String, Object?> toJson() => <String, Object?>{
        'mode': mode.name,
        'imePolicy': imePolicy.name,
        'stageScale': stageScale,
        'stageWidth': stageWidth,
        'stageHeight': stageHeight,
        'containerTop': containerTop,
        'imeStage': imeStage,
        'inputShiftStage': inputShiftStage,
        'contentX': contentX,
        'contentWidth': contentWidth,
        'content': content.toJson(),
        'playerBar': playerBar.toJson(),
        'bands': bands.map((StageRect band) => band.toJson()).toList(),
        'bandCount': bandCount,
        'bandHeight': bandHeight,
        'bandRatio': bandRatio,
        'touchPadding': touchPadding,
        'degeneracies': degeneracies,
        'notes': notes,
      };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is PortraitBands &&
          other.mode == mode &&
          other.imePolicy == imePolicy &&
          other.stageScale == stageScale &&
          other.stageWidth == stageWidth &&
          other.stageHeight == stageHeight &&
          other.containerTop == containerTop &&
          other.imeStage == imeStage &&
          other.inputShiftStage == inputShiftStage &&
          other.contentX == contentX &&
          other.contentWidth == contentWidth &&
          other.content == content &&
          other.playerBar == playerBar &&
          other.bandCount == bandCount &&
          other.bandHeight == bandHeight &&
          other.bandRatio == bandRatio &&
          other.touchPadding == touchPadding &&
          listEquals(other.bands, bands) &&
          listEquals(other.degeneracies, degeneracies) &&
          listEquals(other.notes, notes));

  @override
  int get hashCode => Object.hash(
        mode,
        imePolicy,
        stageScale,
        stageWidth,
        stageHeight,
        containerTop,
        imeStage,
        inputShiftStage,
        contentX,
        contentWidth,
        content,
        playerBar,
        bandCount,
        bandHeight,
        bandRatio,
        touchPadding,
        Object.hashAll(bands),
        Object.hashAll(degeneracies),
        Object.hashAll(notes),
      );

  @override
  String toString() =>
      'PortraitBands(' + mode.name + ', scale: $stageScale, stage: $stageWidth x $stageHeight, bands: $bandCount, degeneracies: $degeneracies)';
}

/// 分带视口：把「内容高 vs 舞台高」的越界变成可测的纯几何。
///
/// Band 候选的带高恒为 1080 舞台单位，所以 1080x2400 时三带总高 3240，
/// 舞台只有 2400，溢出 840。本类不选赢家、不改任何带矩形，只提供：
/// * [overflow] / [overflows]：越界量；
/// * [clampScrollOffset]：把滚动偏移夹到 [0, overflow]；
/// * [visibleRect] / [isBandVisible]：按偏移算出可见窗口；
/// * [offsetToReveal]：把某一带滚进视口的建议偏移。
///
/// 调用方必须在「完整可见」「显式滚动」「拒绝渲染」三者中明确选一个；
/// 本类不提供静默裁切，也不把溢出当成已经解决。
class PortraitBandViewport {
  const PortraitBandViewport({
    required this.stageWidth,
    required this.viewportHeight,
    required this.contentHeight,
    this.tolerance = qtGeometryTolerance,
  })  : assert(stageWidth > 0),
        assert(viewportHeight > 0),
        assert(contentHeight >= 0),
        assert(tolerance >= 0);

  factory PortraitBandViewport.forBands(PortraitBands bands) => PortraitBandViewport(
        stageWidth: bands.stageWidth,
        viewportHeight: bands.bandsViewportHeight,
        contentHeight: bands.bandsContentHeight,
      );

  /// 舞台宽（舞台单位）。
  final double stageWidth;

  /// 可见视口高（舞台单位），等于 stageHeight。
  final double viewportHeight;

  /// 全部分带的总高（舞台单位）。
  final double contentHeight;

  /// 浮点容差。
  final double tolerance;

  /// 内容超出席位的量；不越界时为 0。
  double get overflow => math.max(0.0, contentHeight - viewportHeight);

  /// 是否需要滚动/拒绝裁切才能看到全部分带。
  bool get overflows => overflow > tolerance;

  /// 是否可在不滚动的情况下完整显示。
  bool get fits => !overflows;

  /// 把滚动偏移夹到合法区间；NaN/Infinity 直接报错，不静默当 0。
  double clampScrollOffset(double offset) {
    if (!offset.isFinite) {
      throw ArgumentError('scroll offset must be finite, got $offset');
    }
    if (offset <= 0) {
      return 0;
    }
    if (offset >= overflow) {
      return overflow;
    }
    return offset;
  }

  /// 以舞台坐标表示的可见窗口；[scrollOffset] 会先被 clamp。
  StageRect visibleRect(double scrollOffset) => StageRect(
        0,
        clampScrollOffset(scrollOffset),
        stageWidth,
        viewportHeight,
      );

  /// 某一带是否在给定偏移下完整可见。
  bool isBandVisible(StageRect band, double scrollOffset, {double epsilon = qtGeometryTolerance}) {
    final double offset = clampScrollOffset(scrollOffset);
    return band.y >= offset - epsilon && band.bottom <= offset + viewportHeight + epsilon;
  }

  /// 把某一带滚进视口所需偏移；alignment 0=顶对齐、0.5=居中、1=底对齐。
  double offsetToReveal(StageRect band, {double alignment = 0.5}) {
    if (!band.isPositive()) {
      throw ArgumentError.value(band, 'band', 'must have positive width and height');
    }
    if (!alignment.isFinite || alignment < 0 || alignment > 1) {
      throw ArgumentError.value(alignment, 'alignment', 'must be finite and between 0 and 1');
    }
    final double target = band.y + band.height * alignment - viewportHeight * alignment;
    return clampScrollOffset(target);
  }
}

/// 逐元素比较（本文件不依赖 Flutter，自带一份）。
bool listEquals<T>(List<T> a, List<T> b) {
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

/// Qt 舞台常量。每个值都带源码出处，禁止凭印象改数。
class QtStageGeometry {
  QtStageGeometry._();

  /// 横屏舞台高（舞台单位）。Qt/qml/Main.qml:32。
  /// 注意：舞台宽不是 Qt 常量（Qt 的宽 = width / stageScale，Qt/qml/Main.qml:33），
  /// 竖屏用的 1080 见顶层 portraitStageWidthConstant。
  static const double stageHeightLandscape = qtStageHeightLandscape;

  /// 底栏高。Qt/src/PlayerBar.h:42 RowHeight = 96。
  static const double playerBarHeight = 96;

  /// 底栏在 1080 舞台高上的顶边。Qt/src/NativeHud.cpp:310、Qt/src/NativeHudPlayer.cpp:32-41。
  static const double playerBarTopAtStageHeight1080 = 984;

  /// 内容裁剪底边。Qt/src/NativeHud.cpp:313-327 clip(0, 0, width, 984)。
  static const double contentClipHeight = 984;

  /// 底栏输入层顶边 = 984 - 6。984 来自 Qt/src/NativeHud.cpp:310 的
  /// playerBar(0, 984, width)；Qt/src/PlayerBar.cpp:241-242 的
  /// row(bounds.x(), y, bounds.width(), RowHeight).adjusted(0, -6, 0, 0)
  /// 不含 984 字面量：top 抬到 978，bottom 仍是 1080。
  static const double inputShieldTop = 978;

  /// 底栏输入层高 = 1080 - 978。T02 草案写成 96 并把 bottom 记成 1074，是错的。
  static const double inputBoundsHeight = stageHeightLandscape - inputShieldTop;

  /// 进度条区顶边 = 984 - 6。Qt/src/PlayerBar.cpp:148-151。
  static const double seekTop = inputShieldTop;

  /// 进度条区高。Qt/src/PlayerBar.cpp:148-151。
  static const double seekHeight = 18;

  /// 进度条触摸高（Android）= 18 + 16*2（只做垂直加宽）。Qt/qml/Overlay.qml:495。
  /// 桌面/iOS 是 18，请用 seekTouchHeightFor(android)。
  static const double seekTouchHeight = seekHeight + touchHitPadding * 2;

  /// 音量区宽。Qt/src/PlayerBar.cpp:214 QRectF(volumeX, y + 47, 100, 28)。
  static const double volumeWidth = 100;

  /// 音量区高。Qt/src/PlayerBar.cpp:214。
  static const double volumeHeight = 28;

  /// 音量触摸高（Android）= 28 + 16*2。Qt/qml/Overlay.qml:497。
  /// 桌面/iOS 是 28，请用 volumeTouchHeightFor(android)。
  static const double volumeTouchHeight = volumeHeight + touchHitPadding * 2;

  /// output 列左起点距右边缘。Qt/src/PlayerBar.cpp:238
  /// outputX = bounds.right() - 300（由 PlayerBar.cpp:250 传入 output）。
  ///
  /// 语义是 output 列偏移，不是音量矩形自身的右留白：音量矩形 x = outputX + volumeXOffset，
  /// 右边缘距舞台右边缘 = 300 - 58 - 100 = 142（Qt/src/PlayerBar.cpp:213-214）。
  /// 直接拿 300 当右留白会把音量热区整体左移 58。
  static const double volumeRightInset = 300;

  /// 音量矩形相对 output 列左起点的偏移。Qt/src/PlayerBar.cpp:213 volumeX = x + 58。
  static const double volumeXOffset = 58;

  /// 模态框顶边。Qt/src/NativeHud.cpp:140-159。
  static const double modalTop = 122;

  /// 模态框高。Qt/src/NativeHud.cpp:140-159。
  static const double modalHeight = 836;

  /// 普通模态框最大宽。Qt/src/NativeHud.cpp:153 std::min(1260.0, width - 100)。
  static const double modalDefaultMaxWidth = 1260;

  /// 普通模态框两侧留白之和。Qt/src/NativeHud.cpp:153。
  static const double modalSideInset = 100;

  /// 搜索模态框最小宽。Qt/src/NativeHud.cpp:155。
  static const double modalSearchMinWidth = 760;

  /// 搜索模态框最大宽。Qt/src/NativeHud.cpp:155。
  static const double modalSearchMaxWidth = 1000;

  /// 搜索模态框距右边缘。Qt/src/NativeHud.cpp:155,157。
  static const double modalSearchRightInset = 59;

  /// 搜索结果表顶边。Qt/src/NativeHud.h:96-98。
  static const double resultListTop = 328;

  /// 搜索结果表底边。Qt/src/NativeHud.h:96-98。
  static const double resultListBottom = 758;

  /// 搜索结果表高 = ResultListBottom - ResultListTop = 758 - 328（推导值，Qt 无 430 字面量）。
  /// Qt/src/NativeHud.h:96-98。
  static const double resultListHeight = resultListBottom - resultListTop;

  /// 搜索结果行高。Qt/src/NativeHud.h:96-98。
  static const double resultRowHeight = 72;

  /// 搜索输入框相对模态框的偏移。Qt/src/NativeHud.cpp:175-221、Qt/qml/Overlay.qml:519-536。
  static const double inputTopInset = 180;
  static const double inputHeight = 54;
  static const double inputXInset = 53;
  static const double inputWidthInset = 106;
  static const double inputFontSize = 22;
  static const double inputLeftPadding = 18;
  static const double inputRightPadding = 14;

  /// 设置页视口。Qt/src/NativeHud.h:115-116。
  static const double settingsViewportTop = 176;

  /// 设置页视口底。Qt/src/NativeHud.h:115-116。
  static const double settingsViewportBottom = 836;

  /// 专辑曲目行。Qt/src/NativeHud.h:108-110。
  static const double albumTrackTop = 630;
  static const double albumTrackRowHeight = 48;
  static const double albumTrackRowCount = 6;

  /// Android 触摸层四边加宽量；桌面/iOS 为 0。Qt/qml/Overlay.qml:38
  /// readonly property real touchHitPadding: android ? 16 : 0（37 行注释：桌面/iOS 取 0）。
  /// 平台取值必须走 touchPaddingFor(android)，不要无条件使用本常量。
  static const double touchHitPadding = 16;

  /// 导航区距右边缘。Qt/src/NativeHud.cpp:342-344 navigationLeft = width - 789。
  static const double navigationRightMargin = 789;

  /// 归档遮罩渐隐宽度。Qt/src/NativeHud.cpp:313-327 FadeWidth = 300。
  static const double archiveMaskFadeWidth = 300;

  /// 侧栏钳制区间与公式。Qt/src/NativeHud.cpp:160-166。
  static const double containerSidebarFactor = 0.23;
  static const double containerSidebarOffset = 40;
  static const double containerSidebarMin = 250;
  static const double containerSidebarMax = 340;

  /// 容器左边距。Qt/src/NativeHud.h:38 left = 40（37 行是 struct Layout）。
  static const double containerLeft = 40;

  /// 侧栏与内容之间留白。Qt/src/NativeHud.cpp:163 + 36。
  static const double containerGap = 36;

  /// 浮点容差。
  static const double tolerance = qtGeometryTolerance;

  /// 竖屏分支的宽高比阈值。Qt/src/NativeSceneCamera.cpp:56 portrait = aspect < 1.05（:57 是 compact）。
  static const double portraitAspectThreshold = 1.05;
}

/// 侧栏布局；直接照抄 Qt/src/NativeHud.cpp:160-166。
QtContainerLayout qtContainerLayout(double width) {
  if (!width.isFinite || width <= 0) {
    throw ArgumentError('container layout needs a positive finite width, got $width');
  }
  final double sidebar = math.min(
    QtStageGeometry.containerSidebarMax,
    math.max(
      QtStageGeometry.containerSidebarMin,
      width * QtStageGeometry.containerSidebarFactor - QtStageGeometry.containerSidebarOffset,
    ),
  );
  final double x = QtStageGeometry.containerLeft + sidebar + QtStageGeometry.containerGap;
  return QtContainerLayout(sidebar: sidebar, x: x, width: width - x - QtStageGeometry.containerLeft);
}

/// 模态框矩形；照抄 Qt/src/NativeHud.cpp:140-159。
///
/// 竖屏必须复用这份水平公式（width = 1080），只允许改垂直锚点。
StageRect qtModalBounds(double width, PortraitModalKind kind) {
  if (!width.isFinite || width <= 0) {
    throw ArgumentError('modal bounds need a positive finite stage width, got $width');
  }
  switch (kind) {
    case PortraitModalKind.detailSort:
      final QtContainerLayout layout = qtContainerLayout(width);
      return StageRect(layout.x + 195, 391, 240, 184);
    case PortraitModalKind.lyricsSource:
      return StageRect(width * 0.56 + 156, 674, 232, 232);
    case PortraitModalKind.lyricsOffset:
      return StageRect(width * 0.56, 690, 320, 216);
    case PortraitModalKind.search:
      final double searchWidth = math.min(
        width - 100,
        math.max(
          QtStageGeometry.modalSearchMinWidth,
          math.min(QtStageGeometry.modalSearchMaxWidth, width * 0.5 - QtStageGeometry.modalSearchRightInset),
        ),
      );
      return StageRect(
        width - searchWidth - QtStageGeometry.modalSearchRightInset,
        QtStageGeometry.modalTop,
        searchWidth,
        QtStageGeometry.modalHeight,
      );
    case PortraitModalKind.standard:
      final double standardWidth = math.min(QtStageGeometry.modalDefaultMaxWidth, width - 100);
      return StageRect(
        (width - standardWidth) / 2,
        QtStageGeometry.modalTop,
        standardWidth,
        QtStageGeometry.modalHeight,
      );
  }
}

/// 分带数量：比值只比整数高出容差以内时不得多算一带。
int ceilWithTolerance(double ratio) {
  if (!ratio.isFinite || ratio <= 0) {
    return 1;
  }
  final int ceiled = ratio.ceil();
  if (ceiled > 1 && (ratio - (ceiled - 1)).abs() < qtGeometryTolerance) {
    return ceiled - 1;
  }
  return ceiled;
}

/// 是否走竖屏分支。
///
/// 判据沿用 Qt 自己的竖屏判定：Qt/src/NativeSceneCamera.cpp:56-57
/// const auto aspect = m_width / m_height; const bool portrait = aspect < 1.05;
/// 只按可用尺寸判断，绝不按设备类型判断。
bool prefersPortraitBranch(double layoutWidth, double layoutHeight) {
  if (!layoutWidth.isFinite || !layoutHeight.isFinite || layoutWidth <= 0 || layoutHeight <= 0) {
    throw ArgumentError('portrait branch needs a positive finite window, got $layoutWidth x $layoutHeight');
  }
  return layoutWidth / layoutHeight < QtStageGeometry.portraitAspectThreshold;
}

/// 触摸加宽量：Android 16，其余 0。Qt/qml/Overlay.qml:38-43。
double touchPaddingFor(bool android) => android ? QtStageGeometry.touchHitPadding : 0;

/// 进度条触摸高（按平台）：Android 18+32=50，桌面/iOS 18。Qt/qml/Overlay.qml:495。
double seekTouchHeightFor(bool android) => QtStageGeometry.seekHeight + touchPaddingFor(android) * 2;

/// 音量触摸高（按平台）：Android 28+32=60，桌面/iOS 28。Qt/qml/Overlay.qml:497。
double volumeTouchHeightFor(bool android) => QtStageGeometry.volumeHeight + touchPaddingFor(android) * 2;

/// 四边加宽的触摸命中矩形（命中层专用，绝不回写绘制矩形）。
StageRect expandForTouch(StageRect hit, bool android) => hit.expand(touchPaddingFor(android));

/// 只在垂直方向加宽，保住 x/width（进度条、音量）。
StageRect expandForTouchVertical(StageRect hit, bool android) => hit.expandVertical(touchPaddingFor(android));

/// 算出一次竖屏度量。
///
/// * 竖屏 stageScale 只由逻辑窗口宽决定，安全区与 IME 绝不改它。
/// * stageHeight = (layoutHeight - safe.top - safe.bottom) / stageScale；
///   上下安全区在舞台高度里只扣一次，playerBar 随之抬到手势区之上。
/// * containerTop = safe.top / stageScale：舞台在窗口中的原点，widget 层
///   用它做 Padding.top，底栏底边因此落在 layoutHeight - safe.bottom。
/// * content 是 stage 本地坐标，不再扣 safe.top/safe.bottom（DEDUP-23）。
/// * 左右安全区只收窄内容宽，舞台始终 1080 宽。
/// * 清单保持 adjustResize：平台已按键盘缩小窗口，本函数不读 imeBottom。
/// * 退化情况进 degeneracies 显式暴露；content 高 <= 0 时抛 FlutterError，
///   绝不把负高度交给 Positioned（DEDUP-21）。
PortraitBands computePortraitBands(
  PortraitInputs inputs,
  PortraitBandMode mode, {
  PortraitImePolicy imePolicy = PortraitImePolicy.compress,
}) {
  final double layoutWidth = inputs.layoutWidth;
  final double layoutHeight = inputs.layoutHeight;
  if (!layoutWidth.isFinite || !layoutHeight.isFinite || layoutWidth <= 0 || layoutHeight <= 0) {
    throw ArgumentError('portrait stage needs a positive finite window, got $layoutWidth x $layoutHeight');
  }
  final double stageScale = layoutWidth / portraitStageWidthConstant;
  if (!stageScale.isFinite || stageScale <= 0) {
    throw ArgumentError('portrait stageScale must be positive and finite, got $stageScale');
  }
  final double stageWidth = portraitStageWidthConstant;
  final double touchPadding = touchPaddingFor(inputs.android);

  final List<String> degeneracies = <String>[];
  final List<String> notes = <String>[];

  double inset(double value, String name) {
    if (!value.isFinite) {
      degeneracies.add(name + ' is not finite; treated as 0');
      return 0;
    }
    if (value < 0) {
      degeneracies.add(name + ' is negative; treated as 0');
      return 0;
    }
    return value;
  }

  final double safeTop = inset(inputs.safe.top, 'safe.top');
  final double safeBottom = inset(inputs.safe.bottom, 'safe.bottom');
  final double safeLeft = inset(inputs.safe.left, 'safe.left');
  final double safeRight = inset(inputs.safe.right, 'safe.right');

  // DEDUP-19 唯一公式：上下安全区在舞台高度里只扣一次。
  final double stageHeight = (layoutHeight - safeTop - safeBottom) / stageScale;
  // DEDUP-23：safe.top 只作为舞台在窗口中的原点（乘以 stageScale 后交给
  // widget 层做偏移），不再折成 content 的内缩。
  final double containerTop = safeTop / stageScale;
  final double safeLeftStage = safeLeft / stageScale;
  final double safeRightStage = safeRight / stageScale;

  // DEDUP-20：清单保持 adjustResize，平台已按键盘缩小 layoutHeight；
  // 这里不再读 inputs.imeBottom，imeStage/imeConsumed/inputShift 恒为 0。
  const double imeStage = 0.0;

  final double contentX = safeLeftStage;
  final double contentWidth = stageWidth - safeLeftStage - safeRightStage;
  if (contentWidth <= 0) {
    degeneracies.add('left+right safe area consumes the whole stage width $stageWidth');
  }

  const double inputShiftStage = 0.0;

  final double barHeight = QtStageGeometry.playerBarHeight;
  final StageRect playerBar = StageRect(0, stageHeight - barHeight, stageWidth, barHeight);
  if (playerBar.y < 0) {
    degeneracies.add('stageHeight $stageHeight is shorter than the player bar $barHeight; player bar top is negative');
  }

  final double bandRatio = stageHeight / qtStageHeightLandscape;
  final double bandHeight = qtStageHeightLandscape;
  int bandCount = 1;
  List<StageRect> bands = <StageRect>[];
  // DEDUP-23：content 用 stage 本地坐标；安全区不再出现在这里。
  StageRect content = StageRect(contentX, 0, contentWidth, stageHeight - barHeight);

  switch (mode) {
    case PortraitBandMode.w:
      bandCount = 1;
      // W：舞台顶边就是窗口顶边（safe.top 由 containerTop 偏移），
      // 底栏占满舞台底部，content 底边与 playerBar 顶边重合。
      content = StageRect(contentX, 0, contentWidth, stageHeight - barHeight);
      bands = <StageRect>[StageRect(0, 0, stageWidth, stageHeight)];
      break;
    case PortraitBandMode.band:
      bandCount = ceilWithTolerance(bandRatio);
      bands = List<StageRect>.generate(
        bandCount,
        (int index) => StageRect(0, index * bandHeight, stageWidth, bandHeight),
        growable: false,
      );
      // Band：content 覆盖整个缩放舞台；底栏叠在最后一带上，允许覆盖。
      content = StageRect(contentX, 0, contentWidth, stageHeight);
      notes.add('band mode anchors the player bar to the stage bottom; the last band may extend past it');
      break;
    case PortraitBandMode.hybrid:
      bandCount = 1;
      final StageRect topBar = StageRect(0, 0, stageWidth, barHeight);
      // Hybrid：上下各一条固定 bar，content 只扣 bar，不再扣安全区。
      content = StageRect(contentX, barHeight, contentWidth, stageHeight - barHeight * 2);
      bands = <StageRect>[topBar, content, playerBar];
      break;
  }

  final double finalContentHeight = content.height;
  if (finalContentHeight <= 0) {
    degeneracies.add(
      '[' + mode.name + '] content height is not positive (' + finalContentHeight.toString() +
          '); the window is shorter than the fixed bars, or the safe area leaves no room',
    );
  }

  final PortraitBands result = PortraitBands(
    mode: mode,
    imePolicy: imePolicy,
    stageScale: stageScale,
    stageWidth: stageWidth,
    stageHeight: stageHeight,
    containerTop: containerTop,
    imeStage: imeStage,
    inputShiftStage: inputShiftStage,
    contentX: contentX,
    contentWidth: contentWidth,
    content: content,
    playerBar: playerBar,
    bands: bands,
    bandCount: bandCount,
    bandHeight: bandHeight,
    bandRatio: bandRatio,
    touchPadding: touchPadding,
    degeneracies: degeneracies,
    notes: notes,
  );

  // DEDUP-21：绝不把非正高度的 Positioned 矩形交给框架。
  // 先构造 result，让 degeneracy note 保留在异常消息里供诊断。
  if (result.content.height <= 0) {
    throw FlutterError(
      'PortraitBands refused a non-positive content rect for ' + mode.name + ': ' +
          result.content.toString() + ' in a ' + stageWidth.toString() + ' x ' +
          stageHeight.toString() + ' stage. DEDUP-21 forbids handing a non-positive ' +
          'Positioned rect to the framework. Degeneracies: ' +
          result.degeneracies.join('; '),
    );
  }
  return result;
}
