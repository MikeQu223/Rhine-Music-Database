/// 竖屏舞台 widget 层：把舞台坐标系接到 Flutter 的约束与插图上。
///
/// 责任边界：
/// * 只负责「逻辑窗口 -> 一份 PortraitBands -> 一次缩放绘制」。
/// * 每次约束或 inset 变化都整份重算，绝不缓存上一帧的度量或命中表
///   （Qt 每帧重建命中表：Qt/src/NativeHud.cpp:224-256）。
/// * 不用 OrientationBuilder 按设备类型切换公式，只按可用尺寸判断。
library;

import 'package:flutter/foundation.dart' show FlutterError, defaultTargetPlatform;
import 'package:flutter/widgets.dart';

import 'portrait_bands.dart';

/// 竖屏舞台容器。
///
/// 子 widget 在舞台坐标系里布局（宽固定 PortraitBands.stageWidth），
/// 绘制时整体按 PortraitBands.stageScale 从左上角缩放
/// （Qt/qml/Overlay.qml:179-184 transformOrigin: Item.TopLeft）。
///
/// mode / imePolicy 仍是未裁决候选：默认值只为让宿主可编译、可预览，
/// 不代表赢家；生产接线必须在裁决后显式传参（W / Band / Hybrid 见 fixture）。
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

  /// IME 策略；本阶段不冻结赢家。默认值只用于编译/预览，不是裁决。
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
            imeBottom: media.viewInsets.bottom,
            android: defaultTargetPlatform == TargetPlatform.android,
          ),
          mode,
          imePolicy: imePolicy,
        );
        return PortraitStageScope(
          bands: bands,
          // ClipRect 只把缩放后的舞台裁回它自己的布局盒
          // （stageWidth * stageScale == layoutWidth，stageHeight * stageScale == layoutHeight），
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
                child: Transform.scale(
                  scale: bands.stageScale,
                  alignment: Alignment.topLeft,
                  child: SizedBox(
                    width: bands.stageWidth,
                    height: bands.stageHeight,
                    child: child,
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

/// 在舞台坐标系里按矩形摆放子 widget；必须放在 Stack 里。
class PortraitStageSlot extends StatelessWidget {
  const PortraitStageSlot({super.key, required this.rect, required this.child});

  final StageRect rect;
  final Widget child;

  @override
  Widget build(BuildContext context) => Positioned(
        left: rect.x,
        top: rect.y,
        width: rect.width,
        height: rect.height,
        child: child,
      );
}

/// 按 PortraitBands.bands 铺开分带；每带一个 slot。
///
/// 分带是否需要滚动（以及滚动由谁负责）尚未裁决，这里不做假设。
class PortraitStageBandsView extends StatelessWidget {
  const PortraitStageBandsView({super.key, required this.builder});

  final Widget Function(BuildContext context, int index, StageRect band) builder;

  @override
  Widget build(BuildContext context) {
    final PortraitBands bands = PortraitStageScope.of(context);
    return Stack(
      children: <Widget>[
        for (int index = 0; index < bands.bands.length; index++)
          PortraitStageSlot(
            rect: bands.bands[index],
            child: builder(context, index, bands.bands[index]),
          ),
      ],
    );
  }
}
