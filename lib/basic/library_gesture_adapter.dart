// ===========================================================================
// 资料库列表页「3D 直触区 → 列表拖动」的手势域（requirement m10322-1）。
//
// 用户原话（m10322）：
//   「资料库（列表）页面的3D部分滑动时只响应上下方向，对应绑定翻动列表动作，
//    就是只翻动列表不切换列表。注意原本的切换和翻动列表动作方向不是横平竖直，
//    你可以简单理解成把右侧列表部分的滑动响应范围从仅右侧列表改为扩展到左侧
//    覆盖拦截3D层的直达触控部分」
//
// 做法（不新造一套手势算法）：**不**改曲目列识别，只把「哪块区域可以起手拖动」
// 从「右侧曲目列」扩到「右侧曲目列 ∪ 左侧 3D 直触区（扣掉已有控件）」。
// 拖动仍是 lib/basic/basic_hud.dart 的 _LibraryDragRecognizer（竖直拖动）＋
// 同一个条目单位（88）＋同一个 fractional update（onLibraryScrollUpdate）＋
// 同一个结束 commit（onLibraryScroll），因此：
//   - 只有上下方向产生位移（竖直识别器不认横向位移）；
//   - 不会切换所属列/目录（这里只发窗口位置，不发任何 column/open 动作）；
//   - 不自动播放、不改队列（commit 只是选中）。
//
// 唯一真值仍是舞台坐标矩形（与 basicHudRegionRects 同源），本文件只做纯几何
// 判定，不持有任何 Flutter widget / 状态，方便逐条断言。
// ===========================================================================
import 'dart:ui' show Offset, Rect;

/// 一次「起手拖动是否允许」的判据集合（坐标空间由调用方统一：本地/逻辑坐标）。
///
/// 语义按优先级：
///  1. 落在 [listRect] 内 → 允许（与扩展前完全一致：右侧曲目列任何时候都能拖）；
///  2. 落在 [directTouchRect] 内、且不落在 [controlRects] / [excludedRects] 内 →
///     允许（左侧 3D 直触区起手也走同一条列表拖动）；
///  3. 其余 → 不允许（不参与竞技场，交给原归属，不与已有控件抢手势）。
class LibraryDragDomain {
  const LibraryDragDomain({
    required this.listRect,
    required this.directTouchRect,
    this.controlRects = const <Rect>[],
    this.excludedRects = const <Rect>[],
  });

  /// 右侧曲目列（ruler 裁剪窗口，见 basic_hud.dart 的 basicLibraryListStageRect）。
  final Rect listRect;

  /// 3D 直触区（null = 本次不扩展：非资料库列表阶段/场景尺寸退化）。
  final Rect? directTouchRect;

  /// 已有控件的命中矩形（按钮/设置/播放器/弹层/ruler 行等），扩展区内要扣掉。
  final List<Rect> controlRects;

  /// 整块排除的带状区域（播放条行）：它内部有大量间隙，只靠命中矩形扣不干净。
  final List<Rect> excludedRects;

  /// 这条手势能否从 [point] 起手拖动列表。
  bool allows(Offset point) {
    if (_inside(listRect, point)) {
      return true;
    }
    final Rect? direct = directTouchRect;
    if (direct == null || !_inside(direct, point)) {
      return false;
    }
    for (final Rect rect in controlRects) {
      if (_inside(rect, point)) {
        return false;
      }
    }
    for (final Rect rect in excludedRects) {
      if (_inside(rect, point)) {
        return false;
      }
    }
    return true;
  }

  /// 3D 直触区里「归列表手势」的部分：扣掉控件与排除带后，是否还剩任何一点。
  /// 用于给 ownership 区域图挑一个可用矩形（剩余部分为空时不再拦截场景）。
  bool get hasDirectTouchArea {
    final Rect? direct = directTouchRect;
    if (direct == null || direct.isEmpty) {
      return false;
    }
    return !_fullyCovered(direct, <Rect>[...controlRects, ...excludedRects]);
  }

  static bool _inside(Rect rect, Offset point) {
    return point.dx >= rect.left &&
        point.dx <= rect.right &&
        point.dy >= rect.top &&
        point.dy <= rect.bottom;
  }

  /// 保守判断：[rect] 是否被 [covers] 完全盖住（只在明显被整块盖住时返回 true）。
  /// 不是通用布尔运算——这里只需要「一个控件就吃掉整块直触区」的退化情形。
  static bool _fullyCovered(Rect rect, List<Rect> covers) {
    for (final Rect cover in covers) {
      if (cover.left <= rect.left &&
          cover.top <= rect.top &&
          cover.right >= rect.right &&
          cover.bottom >= rect.bottom) {
        return true;
      }
    }
    return false;
  }
}
