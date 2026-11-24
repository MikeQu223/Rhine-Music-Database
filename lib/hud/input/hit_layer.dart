/// 命中层：Qt/qml/Overlay.qml（权威命中消费层）与 Qt/src/NativeHud.cpp:102-124 的 1:1 迁移。
///
/// 不可变约束（逐条有 Qt 出处）：
/// - hits 必需六字段 x/y/width/height/action/label，写入顺序即 wire 顺序；fixed 只由 PlayerBar
///   附加（Qt/src/PlayerBar.cpp:46-54，全仓唯一写入点，Qt/tests/NativeHudChecks.cpp:484/582 断言），
///   其余 producer 不得写。
/// - 源顺序即 z 序：Qt Quick 把输入交给「包含该点、且在兄弟中最后声明（最上层）」的 delegate，
///   所以最后一个包含点的命中胜出（Qt/qml/Overlay.qml:179-220 的 Repeater）。
///   NativeHud::draw 把播放条命中追加在最后（Qt/src/NativeHud.cpp:309-311、
///   Qt/src/NativeHudPlayer.cpp:36-38），这正是播放条永远压过其它命中的机制。
/// - 触摸外扩只发生在消费侧，pad = android ? 16 : 0（Overlay.qml:38-43），绝不回写源矩形、
///   不逐帧/逐命中重复叠加。
/// - modalOffset 只加在非 fixed 的命中上（Overlay.qml:191）。
/// - playerBounds 屏蔽的区域语义分两条路径看待（与 QML 层级一致）：
///   Overlay.qml:123-142 的 playerBarInputShield 声明在 controls(179，含 hits delegate) 之下，
///   所以落在播放条上的**命中条目**仍先拿到 press；「整块吞掉」精确成立于 Engine 的指针路径
///   （Qt/src/NativeApplication.cpp:216-222，用舞台坐标比 playerBounds）与滚轮路径
///   （Qt/src/NativeHudInput.cpp:14）。isShielded 是这两条路径的谓词模型，不是 hits 的拦路条件。
/// - seek/volume 的命中矩形与 state.seek/state.volume 同源同矩形；x/width 不做触摸外扩，仅
///   y/height 外扩（Overlay.qml:492-497），否则 adjustPlayer 由 mouse.x / width 算出的比例会偏。
/// - 包含判定用闭区间：QML 侧 Overlay.qml:271 显式写「小于等于」，Qt 侧 QRectF::contains 含边
///   （Qt/src/NativeApplication.cpp:221、Qt/src/NativeHudInput.cpp:14）。Dart 的 Rect.contains
///   是右/下半开，直接用会把「正好落在 right/bottom 边上」的点判丢。
///
/// 坐标约定：producer 写入的 x/y/width/height 与 state.playerBounds/seek/volume 都是舞台坐标
/// （Overlay.qml:22 的 stageScale = height / 1080）。QML 先用 mouse.x / stageScale 把逻辑坐标
/// 换算成舞台坐标再交给 Engine（Overlay.qml:96-103、Qt/src/Engine.cpp:1042-1061），
/// NativeApplication::pointer 再用舞台坐标与 playerBounds 比较
/// （Qt/src/NativeApplication.cpp:216-222）。本文件同名同义：几何是舞台坐标，指针入口是逻辑坐标。
/// 窗口→舞台除了除以 scale 还有一次平移：竖屏缩放舞台整体下移 safe.top，
/// 所以 [StageGeometry.toStage] 先除 scale 再减 [StageGeometry.originY]，
/// toLogical/rectToLogical 反向加回；origin 只允许来自 StageGeometry。
/// 唯一例外是 HitLayer.firstResultHit：它的入参是**不含 modalOffset 的舞台坐标**，
/// 理由见该方法注释（与 Qt 的 px/py 空间一致）。
///
/// 依赖： 共享命中模型 lib/hud/protocol/hud_hit.dart（ 拥有，临时接口，freeze 后重审）。
/// 本文件不重定义平行模型，也不复制该类。
library;

import 'dart:ui' show Offset, Rect;

import '../protocol/hud_hit.dart';
import '../scale/hud_scale.dart';

/// 舞台几何：Qt/qml/Overlay.qml:22-23。
///
/// 竖屏全链路只允许一个 scale。挂进 PortraitStage 的缩放子树后，
/// 命中层必须用 [StageGeometry.withScale] 注入 PortraitBands 那一组
/// stageScale/logicalWidth/logicalHeight/originY，不得再按逻辑高度推导一次。
///
/// 窗口→舞台是「先除 scale、再减 [originY]」的一次仿射映射，两段都收在本类里。
/// [originY] 是缩放舞台原点相对窗口顶的**舞台偏移**（stage unit）：竖屏等于
/// PortraitBands.containerTop（= safe.top / stageScale），与 PortraitStage 里
/// Padding(top: containerTop * stageScale) 同源；横屏恒为 0。
/// 命中、无障碍语义矩形、滚轮/指针入口都消费同一份 geometry，调用方禁止各自再加 safe.top。
class StageGeometry {
  /// 旧的全窗口横向构造（仅横屏；stageScale = logicalHeight / 1080）。
  ///
  /// 仅为未迁移调用方保留 const 兼容（test/hud/ime_test.dart、t32 系列、
  /// lib/hud/input/wheel_router.dart）。[stageScale] 是 final 字段，本构造同样显式写入，
  /// 不存在“先留空、读取时再推导”的第二来源。
  ///
  /// [originY] 默认 0：横屏舞台原点就在窗口顶；竖屏禁止走本构造（见上面的 assert）。
  ///
  /// assert 要求 logicalWidth >= logicalHeight：竖屏（width < height）禁止走本构造，
  /// 新代码一律使用 [StageGeometry.withScale] 注入 PortraitBands.stageScale。
  const StageGeometry({required this.logicalWidth, required this.logicalHeight, this.originY = 0.0})
      : assert(
          logicalWidth >= logicalHeight,
          'StageGeometry(...) is landscape-only; portrait must use StageGeometry.withScale',
        ),
        // 横屏没有竖直原点偏移；显式传 originY 时必须有限且非负。
        // const 构造的 assert 只能是常量表达式，double.isFinite 是 getter、不可用，
        // 故写成 `>= 0 && < double.infinity`：NaN 两条都比较为 false，+∞ 过不了上界，
        // 与 `originY.isFinite && originY >= 0` 等价。
        assert(
          originY >= 0 && originY < double.infinity,
          'StageGeometry.originY must be finite and non-negative (landscape keeps 0)',
        ),
        // 横屏：const 构造里只能放常量表达式，夹带（HudScale.landscapeStageScale）
        // 放到工厂 [StageGeometry.landscape] 里做，这里保持原式。
        stageScale = logicalHeight > 0 ? logicalHeight / baseHeight : 1.0;

  /// 横屏生产构造：在 [StageGeometry] 的基础上套 DPI 适配带
  /// （[HudScale.landscapeStageScale]：基准 762dp/1080 = 0.7056，夹在 ±15%）。
  ///
  /// const 构造本身只能放常量表达式，所以 clamp 放在这里；测试里直接调
  /// [StageGeometry] 的用例仍拿到 `logicalHeight / 1080` 的旧口径。
  factory StageGeometry.landscape({
    required double logicalWidth,
    required double logicalHeight,
    double originY = 0.0,
  }) {
    return StageGeometry.withScale(
      stageScale: HudScale.landscapeStageScale(logicalHeight),
      logicalWidth: logicalWidth,
      logicalHeight: logicalHeight,
      originY: originY,
    );
  }

  /// 显式注入唯一 scale；竖屏唯一合法构造。
  ///
  /// [originY] 必须由调用方从 PortraitBands.containerTop 注入（横屏留默认 0）：
  /// 它和绘制侧 Padding(top: containerTop * stageScale) 是同一份平移，不接受第二份推导。
  StageGeometry.withScale({
    required this.stageScale,
    required this.logicalWidth,
    required this.logicalHeight,
    this.originY = 0.0,
  }) {
    if (!stageScale.isFinite || stageScale <= 0) {
      throw ArgumentError.value(stageScale, 'stageScale', 'must be positive and finite');
    }
    // 竖屏唯一平移来源；负值/NaN/∞ 一律拒绝，静默截断会把命中整体挪回错误高度。
    if (!originY.isFinite || originY < 0) {
      throw ArgumentError.value(originY, 'originY', 'must be finite and non-negative');
    }
    if (!logicalWidth.isFinite ||
        !logicalHeight.isFinite ||
        logicalWidth <= 0 ||
        logicalHeight <= 0) {
      throw ArgumentError(
        'StageGeometry.withScale needs positive finite logical size, got $logicalWidth x $logicalHeight',
      );
    }
  }

  /// 逻辑（窗口）尺寸：Overlay.qml 的 width / height。
  final double logicalWidth;
  final double logicalHeight;

  /// 唯一 scale；两个构造都直接写入，读取时不再推导。
  final double stageScale;

  /// 缩放舞台原点相对窗口顶的舞台偏移（stage unit），窗口→舞台的唯一平移来源。
  ///
  /// 竖屏 = PortraitBands.containerTop = safe.top / stageScale（stageScale=1 时就是 safe.top）；
  /// 横屏 = 0。与绘制侧 Padding(top: containerTop * stageScale) 同源：绘制下移多少，
  /// 这里就平移多少，因此 [toStage]/[toLogical]/[rectToLogical] 必须成对使用它。
  final double originY;

  /// Overlay.qml:22 —— 逻辑高度换算到 1080 基准舞台（仅旧横屏构造使用）。
  static const double baseHeight = 1080.0;

  double get stageWidth => stageScale > 0 ? logicalWidth / stageScale : logicalWidth;

  /// 逻辑坐标 → 舞台坐标：QML 里 mouse.x / stageScale，再减掉舞台原点。
  ///
  /// `Offset(lx / stageScale, ly / stageScale - originY)`：竖屏窗口 y=safe.top 落在舞台 y=0，
  /// 窗口 y=0 落在舞台 y=-originY（安全区之上那条窗口带不属于舞台）。
  Offset toStage(Offset logical) =>
      Offset(logical.dx / stageScale, logical.dy / stageScale - originY);

  /// 舞台坐标 → 逻辑坐标：QML 里 stage 值 * stageScale，先把舞台原点加回。
  ///
  /// `Offset(sx * stageScale, (sy + originY) * stageScale)`，是 [toStage] 的精确逆映射。
  Offset toLogical(Offset stage) =>
      Offset(stage.dx * stageScale, (stage.dy + originY) * stageScale);

  /// 舞台矩形 → 逻辑矩形；top/bottom 都经过同一次 `(y + originY) * stageScale` 平移。
  Rect rectToLogical(Rect stage) => Rect.fromLTWH(
        stage.left * stageScale,
        (stage.top + originY) * stageScale,
        stage.width * stageScale,
        stage.height * stageScale,
      );
}

/// 触摸外扩：Qt/qml/Overlay.qml:38-43。
class TouchExpansion {
  const TouchExpansion._();

  /// Android 把每个命中矩形按舞台像素外扩这么多（约 1–1.5mm）。
  static const double androidPad = 16.0;

  static double padFor({required bool android}) => android ? androidPad : 0.0;
}

/// 命中解析：只描述「点到了谁」，不产生副作用。
class HitLayer {
  const HitLayer({
    required this.geometry,
    required this.android,
    this.modal = '',
    this.modalOffset = 0.0,
    this.playerBounds,
  });

  final StageGeometry geometry;
  final bool android;

  /// state.modal；非空即表示有模态遮罩参与 modalOffset 叠加。
  final String modal;

  /// state.modalOffset（舞台坐标）。
  final double modalOffset;

  /// state.playerBounds（舞台坐标）；存在即表示播放条输入屏蔽生效。
  final Rect? playerBounds;

  double get pad => TouchExpansion.padFor(android: android);

  /// Qt 的 QRectF::contains 与 QML 的显式上界比较都是闭区间；Dart 的 Rect.contains 右/下半开。
  ///
  /// 证据：Qt/qml/Overlay.qml:271 显式 px <= area.x + area.width && py <= area.y + area.height；
  /// Qt/src/NativeApplication.cpp:221 与 Qt/src/NativeHudInput.cpp:14 用 QRectF::contains（含边）。
  static bool containsClosed(Rect rect, Offset point) =>
      point.dx >= rect.left &&
      point.dx <= rect.right &&
      point.dy >= rect.top &&
      point.dy <= rect.bottom;

  /// 非 fixed 命中要叠加 modalOffset（Overlay.qml:191）。
  double offsetY(HudHit hit) => hit.y + ((modal.isNotEmpty && !hit.fixed) ? modalOffset : 0.0);

  /// 源矩形 + modalOffset + 触摸外扩。不修改 hit 本身。
  Rect effectiveRect(HudHit hit) =>
      Rect.fromLTWH(hit.x - pad, offsetY(hit) - pad, hit.width + 2 * pad, hit.height + 2 * pad);

  /// 只做触摸外扩、**不含** modalOffset 的扫描矩形（Overlay.qml:38-43 的 hitArea 原义）。
  ///
  /// 只有 firstResultHit 用它：Qt 在 Overlay.qml:266-270 拿 px/py（searchListX/Y + mouse 坐标，
  /// py 不含 modalOffset）去比 hitArea(hit)（同样不含 modalOffset），两点在同一空间。
  Rect scanRect(HudHit hit) =>
      Rect.fromLTWH(hit.x - pad, hit.y - pad, hit.width + 2 * pad, hit.height + 2 * pad);

  /// 播放条输入屏蔽：region = state.playerBounds，按舞台坐标闭区间比较
  /// （Qt/src/NativeApplication.cpp:216-222 收到的正是 QML 除过 stageScale 的舞台坐标）。
  bool isShielded(Offset stagePoint) =>
      playerBounds != null && containsClosed(playerBounds!, stagePoint);

  /// 逻辑坐标便利入口：内部换算成舞台坐标（Overlay.qml:96-103 的 mouse.x / stageScale）。
  bool isShieldedLogical(Offset logicalPoint) => isShielded(geometry.toStage(logicalPoint));

  /// 最上层（wire 顺序最后一个）包含该点的命中；无命中返回 null。
  ///
  /// Qt Quick 对重叠兄弟项把事件交给最后声明的那一个（Repeater 的 delegate 按 wire 顺序同级，
  /// Overlay.qml:179-220 全部 z=0、无 mouse.accepted=false 反转），所以这里是「最后一个胜出」
  /// 而非「第一个胜出」；播放条命中在 NativeHud 里最后追加（Qt/src/NativeHud.cpp:309-311），
  /// 因此永远压过其它命中。
  HudHit? hitAt(List<HudHit> hits, Offset logicalPoint) {
    final stagePoint = geometry.toStage(logicalPoint);
    // 两趟扫描：先只认**源矩形**包含该点的命中（同样「最后一个胜出」），
    // 一个都没有才退回触摸外扩后的矩形。
    //
    // 原因是外扩 pad=16 相对相邻键的间距太大：播放条上「词」与「MV」两个 48 宽
    // 的键中心只隔 55，外扩后各自的矩形互相侵入 25 单位，而 MV 在 wire 顺序里
    // 更靠后 ⇒ 点「词」的右半格会打开 MV（用户 2026-11-23 报的「横屏底栏按钮
    // 点了没反应」，实测 `player:lyrics` 的右缘被 `player:mv` 吃掉）。精确命中
    // 优先只影响「两个键的外扩区重叠」这一种情形，手指落在哪个键的源矩形里就
    // 算哪个键，落在外扩区时才沿用原来的最后胜出规则。
    HudHit? found;
    for (var index = 0; index < hits.length; index++) {
      final HudHit hit = hits[index];
      if (containsClosed(
        Rect.fromLTWH(hit.x, offsetY(hit), hit.width, hit.height),
        stagePoint,
      )) {
        found = hit;
      }
    }
    if (found != null) {
      return found;
    }
    for (var index = 0; index < hits.length; index++) {
      if (containsClosed(effectiveRect(hits[index]), stagePoint)) {
        found = hits[index];
      }
    }
    return found;
  }

  /// 结果列表扫描用的前缀（Overlay.qml:268-272）。
  static const List<String> resultPrefixes = <String>['music:result:', 'music:expand:'];

  /// searchScrollArea 的抬起点命中：正向遍历 wire 顺序，第一个命中前缀且包含该点的胜出
  /// （Overlay.qml:266-279 的 for 循环，break 在 273-276），与 hitAt 的「最后一个胜出」
  /// 是相反规则。
  ///
  /// stagePoint 是**不含 modalOffset 的舞台坐标**：Qt 的 px = searchListX + mouse.x、
  /// py = searchListY + mouse.y（Overlay.qml:266-267，py 刻意不含 modalOffset，因为 mouse 坐标
  /// 已经活在 modalOffset 生效的那个 item 里），比的是 hitArea(hit)（:270，同样不含 modalOffset）。
  /// 调用方必须按同一空间换算，不能用 effectiveRect。
  HudHit? firstResultHit(List<HudHit> hits, Offset stagePoint) {
    for (var index = 0; index < hits.length; index++) {
      final hit = hits[index];
      if (!hasResultPrefix(hit.action)) {
        continue;
      }
      if (containsClosed(scanRect(hit), stagePoint)) {
        return hit;
      }
    }
    return null;
  }

  static bool hasResultPrefix(String action) {
    for (final prefix in resultPrefixes) {
      if (action.startsWith(prefix)) {
        return true;
      }
    }
    return false;
  }

  /// 命中触发的时机：iOS 在抬起且释放点仍落在同一命中才发（Overlay.qml:199-212 的
  /// onClicked，:204 的 if (!overlay.ios) rhine.action(...) 是按下即发的分支）；
  /// 非 iOS（Android，以及 Overlay.qml:27-37 里存在的 desktop windows/osx）按下即发。
  ///
  /// 判据取「非 ios」而不是「android」：Qt 的条件就是 !overlay.ios，桌面同理按下即发；
  /// 当前 Flutter 树只有 android/ 平台目录，故这里只支持 Android。
  static bool firesOnPress({required bool ios}) => !ios;

  /// seek/volume 的 x/width 不做触摸外扩，仅 y/height 外扩（Overlay.qml:492-497）。
  Rect playerControlRect(Rect region) =>
      Rect.fromLTWH(region.left, region.top - pad, region.width, region.height + 2 * pad);

  /// Engine.cpp:1016-1021 的 adjustPlayer：width<=0 或 control 非 seek/volume 时拒绝，
  /// 否则构造 player:<control>-fraction:<数值>。
  static String? playerFractionAction(
      {required String control, required double x, required double width}) {
    if (width <= 0) {
      return null;
    }
    if (control != 'seek' && control != 'volume') {
      return null;
    }
    final fraction = (x / width).clamp(0.0, 1.0).toDouble();
    return 'player:$control-fraction:${formatG16(fraction)}';
  }

  /// 与 Qt 的 QString::number(v, 'g', 16) 对齐：16 位有效数字、去掉尾随零，
  /// 且十进指数 < -4 或 >= 16 时切换成指数记法（C/Qt 的 %g 规则）。
  ///
  /// 已知偏差：Dart 没有直接等价的 'g'，此处用 toStringAsExponential(15) 取 16 位有效数字
  /// 后自行排版；极端值的舍入可能与 qdtoa 差最后一位（adjustPlayer 的 fraction 在 [0,1]，
  /// 该情形实际不可达）。
  /// -0.0 在此返回 '0'：adjustPlayer 的 x 由 (mouse.x - region.left) 得到、width > 0，
  /// 商恒为 +0.0，负零不可达。
  static String formatG16(double value) {
    if (value.isNaN) {
      return 'nan';
    }
    if (value.isInfinite) {
      return value.isNegative ? '-inf' : 'inf';
    }
    if (value == 0.0) {
      return '0';
    }
    final negative = value < 0.0;
    final scientific = value.abs().toStringAsExponential(15);
    final marker = scientific.indexOf('e');
    final mantissa = scientific.substring(0, marker);
    final exponent = int.parse(scientific.substring(marker + 1).replaceFirst('+', ''));
    var digits = mantissa.replaceFirst('.', '');
    var end = digits.length;
    while (end > 1 && digits[end - 1] == '0') {
      end--;
    }
    digits = digits.substring(0, end);
    final sign = negative ? '-' : '';
    if (exponent < -4 || exponent >= 16) {
      final tail = digits.length > 1 ? '.${digits.substring(1)}' : '';
      final expSign = exponent < 0 ? '-' : '+';
      final expDigits = exponent.abs().toString().padLeft(2, '0');
      return '$sign${digits.substring(0, 1)}${tail}e$expSign$expDigits';
    }
    if (exponent >= 0) {
      final intDigits = exponent + 1;
      if (digits.length <= intDigits) {
        return sign + digits.padRight(intDigits, '0');
      }
      return '$sign${digits.substring(0, intDigits)}.${digits.substring(intDigits)}';
    }
    final zeros = '0' * (-exponent - 1);
    return '${sign}0.$zeros$digits';
  }
}
