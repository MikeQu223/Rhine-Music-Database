/// 竖屏舞台 widget 层：把舞台坐标系接到 Flutter 的约束与插图上。
///
/// 责任边界：
/// * 只负责「逻辑窗口 -> 一份 PortraitBands -> 一次缩放绘制」。
/// * 每次约束或 inset 变化都整份重算，绝不缓存上一帧的度量或命中表
///   （Qt 每帧重建命中表：Qt/src/NativeHud.cpp:224-256）。
/// * 不用 OrientationBuilder 按设备类型切换公式，只按可用尺寸判断。
library;

import 'package:flutter/foundation.dart' show FlutterError, TargetPlatform, defaultTargetPlatform;
import 'package:flutter/widgets.dart';

import '../../hud/input/hit_layer.dart';
import '../../hud/protocol/hud_frame.dart';
import 'portrait_bands.dart';

/// 竖屏舞台容器。
///
/// 子 widget 在舞台坐标系里布局（宽固定 PortraitBands.stageWidth），
/// 绘制时整体按 PortraitBands.stageScale 从左上角缩放
/// （Qt/qml/Overlay.qml:179-184 transformOrigin: Item.TopLeft）。
///
/// 舞台在窗口中的原点是 (0, containerTop * stageScale) == (0, safe.top)。
/// stageHeight 已经不含上下安全区，所以整个缩放舞台必须下移这一段；否则底栏
/// 底边会停在 layoutHeight - safe.top - safe.bottom。缩放后舞台高
/// = layoutHeight - safe.top - safe.bottom，底边恰好在 layoutHeight - safe.bottom。
///
/// 这份平移只有两个消费者，且必须同源：绘制用 Padding(top: containerTop * stageScale)
/// 把缩放舞台下移；命中/无障碍语义用 StageGeometry.originY = containerTop 把窗口逻辑坐标
/// 反向平移回舞台坐标。二者都由 bands.containerTop 算出，任何子树不得再自己加 safe.top。
///
/// mode 仍是未裁决候选：默认值只为让宿主可编译、可预览，不代表赢家。
/// imePolicy 在 adjustResize 下不参与几何，仅为源码兼容保留。
class PortraitStage extends StatelessWidget {
  const PortraitStage({
    super.key,
    required this.child,
    this.mode = PortraitBandMode.hybrid,
    this.imePolicy = PortraitImePolicy.compress,
    this.debugLabel,
  });

  /// 舞台坐标系里的内容。
  final Widget child;

  /// 分带候选；本阶段不冻结赢家。默认值只用于编译/预览，不是裁决。
  final PortraitBandMode mode;

  /// IME 策略；adjustResize 下恒为 no-op，仅为源码兼容保留。
  final PortraitImePolicy imePolicy;

  /// 只用于诊断定位，不参与几何。
  final String? debugLabel;

  @override
  Widget build(BuildContext context) {
    final MediaQueryData media = MediaQuery.of(context);
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final Size available = constraints.biggest;
        final double layoutWidth = available.width.isFinite ? available.width : media.size.width;
        final double layoutHeight = available.height.isFinite ? available.height : media.size.height;
        final PortraitBands bands = computePortraitBands(
          PortraitInputs(
            layoutWidth: layoutWidth,
            layoutHeight: layoutHeight,
            safe: PortraitInsets(
              top: media.padding.top,
              bottom: media.padding.bottom,
              left: media.padding.left,
              right: media.padding.right,
            ),
            // 清单保持 adjustResize，平台已按键盘缩小窗口；
            // 这里不读 media.viewInsets.bottom，避免二次扣除。
            android: defaultTargetPlatform == TargetPlatform.android,
          ),
          mode,
          imePolicy: imePolicy,
        );
        // 唯一一份 StageGeometry 由 PortraitStage 生成并注入。
        // 绘制（Transform.scale）与命中（HitLayer/PointerRouter）都消费这一份；
        // 子树不得再用 logicalHeight / 1080 推导第二个 scale。
        // originY 与下面 Padding(top: containerTop * stageScale) 同源——
        // 绘制下移多少，命中/语义就平移多少；横屏 containerTop = 0，originY 退化为 0。
        final StageGeometry geometry = StageGeometry.withScale(
          stageScale: bands.stageScale,
          logicalWidth: layoutWidth,
          logicalHeight: layoutHeight,
          originY: bands.containerTop,
        );
        return PortraitStageScope(
          bands: bands,
          // ClipRect 只把缩放后的舞台裁回它自己的布局盒
          // （stageWidth * stageScale == layoutWidth；
          //   stageHeight * stageScale == layoutHeight - safe.top - safe.bottom），
          // 防止亚像素溢出糊到相邻区域。它不是内容裁切：舞台内所有入口/动作矩形原样保留，
          // 这里不做隐藏、不裁切可用区、也不二次缩放。
          child: ClipRect(
            key: debugLabel == null ? null : ValueKey<String>('portrait-stage-' + debugLabel!),
            child: SizedBox(
              width: layoutWidth,
              height: layoutHeight,
              // OverflowBox 让舞台拿到自己的尺寸（stageWidth x stageHeight）。
              // 若直接把舞台放进紧约束里，内层 SizedBox 会被压回逻辑尺寸，
              // 缩放就会被算两次（绘制尺寸 = 逻辑尺寸 x stageScale）。
              child: OverflowBox(
                alignment: Alignment.topLeft,
                minWidth: 0,
                maxWidth: double.infinity,
                minHeight: 0,
                maxHeight: double.infinity,
                // 舞台原点 = (0, safe.top)。stageHeight 已不含上下安全区，
                // 这里把整个缩放舞台下移 containerTop * stageScale；OverflowBox 给的是
                // 自由约束，Padding 不会压缩舞台，缩放仍只有 Transform 这一处。
                child: Padding(
                  padding: EdgeInsets.only(top: bands.containerTop * bands.stageScale),
                  child: Transform.scale(
                    scale: bands.stageScale,
                    alignment: Alignment.topLeft,
                    child: SizedBox(
                      width: bands.stageWidth,
                      height: bands.stageHeight,
                      // 全链路只保留 PortraitStage 这一次缩放。
                      // 子树拿到单位缩放的舞台（1080 x stageHeight），绘制与命中
                      // 都从这一份 HudStage 读尺寸，禁止再调 HudStage.fromLogicalSize。
                      child: StageGeometryScope(
                        geometry: geometry,
                        child: HudStageScope(
                          stage: HudStage(
                            scale: 1.0,
                            // 恒定 1080，与 PortraitBands.stageWidth 同一常量。
                            width: portraitStageWidthConstant,
                            height: bands.stageHeight,
                          ),
                          child: child,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// 把当次度量交给子树；同一帧内所有绘制与命中都读这一份。
class PortraitStageScope extends InheritedWidget {
  const PortraitStageScope({super.key, required this.bands, required super.child});

  final PortraitBands bands;

  static PortraitBands of(BuildContext context) {
    final PortraitBands? bands = maybeOf(context);
    if (bands == null) {
      throw FlutterError(
        'PortraitStageScope.of() was called with a context that does not contain '
        'a PortraitStage.\n'
        'The context must be a descendant of a PortraitStage widget; '
        'use PortraitStageScope.maybeOf() when a stage is optional.',
      );
    }
    return bands;
  }

  static PortraitBands? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<PortraitStageScope>()?.bands;

  @override
  bool updateShouldNotify(PortraitStageScope oldWidget) => oldWidget.bands != bands;
}

/// 把唯一一份单位缩放舞台交给绘制/命中子树。
///
/// 必须挂在 [PortraitStage] 的缩放子树内部：stage.scale 恒为 1.0，
/// stage.width 恒为 1080，stage.height 为 PortraitBands.stageHeight。
/// 子树禁止再按逻辑窗口高度推导 scale；命中层用 StageGeometry.withScale
/// 注入同一组 stageScale/logicalWidth/logicalHeight。
class HudStageScope extends InheritedWidget {
  const HudStageScope({super.key, required this.stage, required super.child});

  final HudStage stage;

  static HudStage of(BuildContext context) {
    final HudStage? stage = maybeOf(context);
    if (stage == null) {
      throw FlutterError(
        'HudStageScope.of() was called with a context that does not contain a '
        'PortraitStage.\n'
        'The context must be a descendant of PortraitStage; use '
        'HudStageScope.maybeOf() when a stage is optional.',
      );
    }
    return stage;
  }

  static HudStage? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<HudStageScope>()?.stage;

  @override
  bool updateShouldNotify(HudStageScope oldWidget) =>
      oldWidget.stage.scale != stage.scale ||
      oldWidget.stage.width != stage.width ||
      oldWidget.stage.height != stage.height;
}

/// 把唯一一份 [StageGeometry] 注入绘制/命中子树。
///
/// 与 [HudStageScope] 同源：geometry.stageScale == PortraitBands.stageScale，
/// geometry.logicalWidth/Height == LayoutBuilder 的完整可用窗口，
/// geometry.originY == PortraitBands.containerTop（唯一平移来源）。HitLayer、
/// PointerRouter、TextInputStageState 只能消费这里的 scale 与 origin，禁止在子树内重算，
/// 也禁止各自再补一次 safe.top。
class StageGeometryScope extends InheritedWidget {
  const StageGeometryScope({super.key, required this.geometry, required super.child});

  final StageGeometry geometry;

  static StageGeometry of(BuildContext context) {
    final StageGeometry? geometry = maybeOf(context);
    if (geometry == null) {
      throw FlutterError(
        'StageGeometryScope.of() was called with a context that does not contain '
        'a PortraitStage.\n'
        'The context must be a descendant of PortraitStage; use '
        'StageGeometryScope.maybeOf() when a stage is optional.',
      );
    }
    return geometry;
  }

  static StageGeometry? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<StageGeometryScope>()?.geometry;

  @override
  bool updateShouldNotify(StageGeometryScope oldWidget) =>
      oldWidget.geometry.stageScale != geometry.stageScale ||
      oldWidget.geometry.logicalWidth != geometry.logicalWidth ||
      oldWidget.geometry.logicalHeight != geometry.logicalHeight ||
      // 只改 originY（例如 inset 变化但 scale 不变）时也必须重发，
      // 否则命中/语义会继续读到上一帧的平移量。
      oldWidget.geometry.originY != geometry.originY;
}

/// 在舞台坐标系里按矩形摆放子 widget；必须放在 Stack 里。
class PortraitStageSlot extends StatelessWidget {
  const PortraitStageSlot({super.key, required this.rect, required this.child});

  final StageRect rect;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!rect.isPositive() || !rect.x.isFinite || !rect.y.isFinite) {
      throw FlutterError(
        'PortraitStageSlot refused a non-positive or non-finite rect: ' +
            rect.toString() +
            '. DEDUP-21 forbids handing it to Positioned; fix the band/content '
            'geometry instead of clamping silently.',
      );
    }
    return Positioned(
      left: rect.x,
      top: rect.y,
      width: rect.width,
      height: rect.height,
      child: child,
    );
  }
}

/// 按 PortraitBands.bands 铺开分带；每带一个 slot。
///
/// 分带溢出（Band 候选在 1080x2400 时第三带尾部有 840 舞台单位超出舞台）
/// 不再被 Stack 的默认 clip 静默吃掉。调用方必须显式二选一：
/// * [scrollable] = false（默认）：只在 [PortraitBandViewport.fits] 时渲染；
///   一旦溢出就抛 [FlutterError]，拒绝把不可达动作当成可用；
/// * [scrollable] = true：套一个显式 [SingleChildScrollView]，由调用方/
///   测试通过 [scrollController] 或 Scrollable 位置访问被遮住的带。
///
/// 本 widget 不选 Band 赢家，不改变任何 band 矩形，也不替业务决定滚动归属。
class PortraitStageBandsView extends StatelessWidget {
  const PortraitStageBandsView({
    super.key,
    required this.builder,
    this.scrollable = false,
    this.scrollController,
  });

  final Widget Function(BuildContext context, int index, StageRect band) builder;

  /// 是否允许用显式滚动视口承载溢出分带。默认拒绝不安全裁切。
  final bool scrollable;

  /// 可选滚动控制器；与 [scrollable] 一起使用。
  final ScrollController? scrollController;

  @override
  Widget build(BuildContext context) {
    final PortraitBands bands = PortraitStageScope.of(context);
    final PortraitBandViewport viewport = bands.bandViewport;
    if (viewport.overflows && !scrollable) {
      throw FlutterError(
        'PortraitStageBandsView refuses to clip ${bands.mode.name} bands: '
        'content is ${viewport.contentHeight} stage units but the stage viewport is '
        '${viewport.viewportHeight} (overflow ${viewport.overflow}). '
        'Pass scrollable: true to place the bands in an explicit '
        'SingleChildScrollView, or choose a candidate that fits. '
        'Silent clipping would hide reachable actions.',
      );
    }
    final Widget stack = Stack(
      // 分带自身可以超出 Stack；是否可见由外层滚动视口或舞台边界明确决定，
      // 不在这里用默认 clip 把越界内容静默裁掉。
      clipBehavior: Clip.none,
      children: <Widget>[
        for (int index = 0; index < bands.bands.length; index++)
          PortraitStageSlot(
            rect: bands.bands[index],
            child: builder(context, index, bands.bands[index]),
          ),
      ],
    );
    if (!viewport.overflows) {
      return stack;
    }
    return SingleChildScrollView(
      controller: scrollController,
      primary: false,
      scrollDirection: Axis.vertical,
      child: SizedBox(
        width: bands.stageWidth,
        height: viewport.contentHeight,
        child: stack,
      ),
    );
  }
}
