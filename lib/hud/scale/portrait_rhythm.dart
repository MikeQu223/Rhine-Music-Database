/// 竖屏页面的垂直节奏（相对布局的公共入口）。
///
/// 背景：竖屏画布的高度不是常量——`PortraitCanvas.height` = 舞台高 / 画布单位，
/// 同一份 393 网格设计稿在 20:9 手机上得到约 698 网格，在 4:3 平板上只有约 520
/// 网格。各页原先把「区块之间的推进量」写成固定网格常量（128 / 264 / 236 …），
/// 于是矮屏上内容被压到裁剪线以下、高屏上顶部留出一大条空白——用户报的
/// 「流式布局挤压」就是这件事。
///
/// 规则（与具体机型无关，只看本页可用高）：
/// * 只缩放**间距与区块推进量**，绝不缩放字号/图标——字号变小就不可读了；
/// * 缩放系数夹在 [minFactor, 1]：矮屏收到 0.78 为止，再矮就让内容**滚动**，
///   而不是继续压缩（压缩到某个程度就是「挤压」本身）；
/// * 内容总量放不下时，页面必须给出滚动通道（[/*scroll*/] 参数），不许静默截断。
library;

import 'dart:math' as math;

class PortraitRhythm {
  const PortraitRhythm._();

  /// 设计稿的可用内容高（网格）：`PortraitCanvas.contentBottom` 的缺省值 693
  /// 与 698.67 的参考页高对齐，取两者中较保守的一个。
  static const double designContentHeight = 693.0;

  /// 间距最多收到设计稿的 78%：再小段落之间就粘在一起了。
  static const double minFactor = 0.78;

  /// 本页的节奏系数（随可用高单调，最大 1）。
  static double of(double contentHeight) {
    if (!contentHeight.isFinite || contentHeight <= 0) {
      return 1.0;
    }
    return (contentHeight / designContentHeight).clamp(minFactor, 1.0);
  }

  /// 按节奏缩放一个设计稿间距。
  static double gap(double base, double contentHeight) =>
      base * of(contentHeight);

  /// 按节奏缩放一个「从页头基准往下推」的绝对位置。
  ///
  /// 语义：设计稿上 `top` 距 `anchor` 有 `top - anchor` 的推进量，矮屏按节奏收，
  /// 但绝不越过 `anchor` 本身。`anchor` 通常是页头下沿或封面下沿。
  static double below(double anchor, double top, double contentHeight) {
    final double delta = top - anchor;
    if (delta <= 0) {
      return math.max(top, anchor);
    }
    return anchor + delta * of(contentHeight);
  }
}
