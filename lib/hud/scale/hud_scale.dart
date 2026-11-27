/// 屏幕尺寸 / DPI 适配：把「舞台像素」换算成「逻辑 dp」的唯一出口。
///
/// 横屏：`stageScale = 逻辑高 / 1080`，舞台高恒 1080。
/// 竖屏：`1 网格 = clamp(逻辑宽 / 393, 0.9, 1.3) dp`，页面仍铺满屏宽，
/// 元素保持设计稿网格尺寸，于是「元素变小、页面不变」。
///
/// 只放常量与纯函数；绘制、命中、输入层都必须从这里取数。
library;

import 'dart:math' as math;

class HudScale {
  const HudScale._();

  /// Qt compact 设计稿的手机网格宽（`Qt/src/ResponsiveHudLayout.cpp` 的 393）。
  static const double designGridWidth = 393.0;

  /// 舞台高（横竖屏一致，`Qt/qml/Main.qml:32`、`hit_layer.dart` 的 baseHeight）。
  static const double designStageHeight = 1080.0;

  /// 舞台像素 / 设计网格：竖屏画布的命令流 `scale(unit, unit)` 用它。
  ///
  /// 与屏幕无关的常量：1080 / 393 = 2.74758…。屏幕只影响 stageScale（dp/舞台像素），
  /// 不再影响这个比值，否则「1 网格有多少 dp」就无法被 clamp 控制。
  static const double stageUnit = designStageHeight / designGridWidth;

  /// 竖屏每网格可取的最小 / 最大 dp（用户选定的 [0.9, 1.3] 带）。
  static const double minGridDp = 0.9;
  static const double maxGridDp = 1.3;

  /// 横屏基准：验收机 762dp 逻辑高 / 1080 → 1 舞台像素 0.7056dp。
  static const double landscapeBaseStageDp = 762.0 / designStageHeight;


  /// 竖屏：一个设计网格等于多少逻辑 dp。
  static double gridDp(double logicalWidth) {
    if (!logicalWidth.isFinite || logicalWidth <= 0) {
      return 1.0;
    }
    return (logicalWidth / designGridWidth).clamp(minGridDp, maxGridDp);
  }

  /// 竖屏：逻辑 dp / 舞台像素（= PortraitBands 注入的 stageScale）。保留给未来的
  /// 舞台级缩放用；当前竖屏仍由 PortraitBands 铺满宽度（舞台宽恒 1080），DPI 适配
  /// 通过 [portraitUnitFactor] 与 [portraitGridWidth] 在画布网格里做，见文件头说明。
  static double portraitStageScale(double logicalWidth) => gridDp(logicalWidth) / stageUnit;

  /// 竖屏画布单位的压缩系数（≤1）：把「铺满宽度」的网格压进 [minGridDp, maxGridDp]。
  ///
  /// PortraitBands 的竖屏舞台宽恒 1080（`portraitStageWidthConstant`），所以
  /// 逻辑宽 = 1080 × stageScale；铺满时 1 网格 = 逻辑宽 / 393 dp。这个值超过 1.3
  /// （本机 1.94）时就要按比例压回 1.3，压回去的比例就是本函数返回值。
  /// 窄屏（铺满时已小于 0.9）返回 1：宁可小一点也不裁切内容。
  static double portraitUnitFactor(double stageScale) {
    if (!stageScale.isFinite || stageScale <= 0) {
      return 1.0;
    }
    final double logicalWidth = designStageHeight * stageScale;
    final double natural = logicalWidth / designGridWidth;
    if (natural <= maxGridDp) {
      return 1.0;
    }
    return maxGridDp / natural;
  }

  /// 横屏：逻辑 dp / 舞台像素（线性，等同旧口径）。
  static double landscapeStageScale(double logicalHeight) {
    if (!logicalHeight.isFinite || logicalHeight <= 0) {
      return landscapeBaseStageDp;
    }
    // 横屏本来就按「逻辑高 / 1080」算舞台（Qt 视口语义），它已经跟随屏幕尺寸；
    // 再夹一个浮动带会把小窗口的舞台硬改成别的比例，与 Qt 不一致，故保持线性。
    return logicalHeight / designStageHeight;
  }


  /// 竖屏画布单位：`舞台宽 / 393 × 压缩系数`（舞台单位/网格）。
  static double portraitUnit(double stageWidth, double stageScale) {
    if (!stageWidth.isFinite || stageWidth <= 0) {
      return stageUnit;
    }
    return stageWidth / designGridWidth * portraitUnitFactor(stageScale);
  }

  /// 竖屏页面实际可用的网格宽度（= 舞台宽 / 画布单位）。
  ///
  /// 1 网格被夹到 1.3dp 之后，横向能容下的网格数比设计稿的 393 更多（本机 586），
  /// 布局必须按这个宽度算右缘，页面才铺满屏宽而元素尺寸不变。
  static double portraitGridWidth(double stageWidth, double stageScale) {
    final double unit = portraitUnit(stageWidth, stageScale);
    if (!unit.isFinite || unit <= 0 || !stageWidth.isFinite || stageWidth <= 0) {
      return designGridWidth;
    }
    return math.max(designGridWidth, stageWidth / unit);
  }
}
