import 'package:flutter/widgets.dart';

import '../hud/pages/viewer_hud.dart';
import '../hud/protocol/hud_frame.dart';
import '../hud/render/hud_painter.dart';
import '../scene/viewer_state.dart';
import 'basic_hud_resources.dart';

/// 封面查看器（Qt `NativeViewer`）在 Flutter 侧的 HUD 层。
///
/// 为什么需要这一层：Qt 的查看器只在 `frame["viewer"]` 为真时画自己的
/// viewer 页（NativeHud.cpp:267-268），而内嵌（Flutter-only Android）时 Qt 没有
/// 自己的命中层与原生输入面——HUD 的所有文字/按钮都是 Flutter 画的。查看器一旦
/// 打开，详情页的 HUD 就不能再画（否则两份 overlay 叠在一起），所以外壳在查看器
/// 期间换用本层的命令流，3D 场景层仍然是同一个 PlatformView（key 不变，只被移动）。
///
/// 命令与命中全部来自 [renderViewerHud]（与 Qt NativeHudDetail.cpp:513-529 逐字对应
/// 的移植），本文件只做两件事：把命令流交给 [HudStagePainter]，把命中按 Qt 的顺序
/// （append-only，反向遍历）折成动作串。绘制顺序、坐标、文本都不在这里重新推导。
class BasicCoverViewerOverlay extends StatelessWidget {
  const BasicCoverViewerOverlay({
    super.key,
    required this.stage,
    required this.ports,
    required this.state,
    required this.onAction,
  });

  /// 舞台几何（横屏 0..width / 0..984，竖屏 0..1080），与设置浮层共用一份。
  final HudStage stage;
  final BasicGlyphPorts ports;
  final ViewerHudState state;
  final ValueChanged<String> onAction;

  @override
  Widget build(BuildContext context) {
    final ViewerHudDrawing drawing = renderViewerHud(
      state,
      stage.width,
      glyphs: BasicCoverViewerGlyphs(ports),
    );
    final HudFrameEnvelope envelope = HudFrameEnvelope.decode(<String, Object?>{
      'generation': 0,
      'frame': <String, Object?>{},
      'commands': drawing.commands,
      'hits': const <Object?>[],
      'state': <String, Object?>{},
    });
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapUp: (TapUpDetails details) {
        final String? action = _hitAt(drawing.hits, details.localPosition);
        if (action != null) {
          onAction(action);
        }
      },
      child: CustomPaint(
        painter: HudStagePainter(
          envelope: envelope,
          ports: HudPainterPorts(
            text: ports.draw,
            path: ports.pathFor,
            image: ports.imageFor,
          ),
          stage: stage,
        ),
        child: const SizedBox.expand(),
      ),
    );
  }

  /// 与 [BasicDiscWarningOverlay] 同一条口径：命中是 stage 坐标，本地坐标先除以
  /// stage.scale；反向遍历实现"后画的先命中"（NativeHud 的 append-only 顺序）。
  String? _hitAt(List<Map<String, Object?>> hits, Offset local) {
    final double scale = stage.scale > 0 ? stage.scale : 1.0;
    final Offset point = Offset(local.dx / scale, local.dy / scale);
    for (int index = hits.length - 1; index >= 0; index--) {
      final Map<String, Object?> hit = hits[index];
      final double x = (hit['x'] as num?)?.toDouble() ?? 0;
      final double y = (hit['y'] as num?)?.toDouble() ?? 0;
      final double width = (hit['width'] as num?)?.toDouble() ?? 0;
      final double height = (hit['height'] as num?)?.toDouble() ?? 0;
      if (Rect.fromLTWH(x, y, width, height).contains(point)) {
        return hit['action'] as String?;
      }
    }
    return null;
  }
}

/// [ViewerHudGlyphsPort] 的适配：Qt 的 `Glyphs::width()` 在本仓只有
/// [BasicGlyphPorts] 一处真值（与 ruler/player/lyrics 共用同一套字形）。
class BasicCoverViewerGlyphs implements ViewerHudGlyphsPort {
  const BasicCoverViewerGlyphs(this.ports);

  final BasicGlyphPorts ports;

  @override
  double width(String value, double size, String weight, [double tracking = 0]) {
    if (value.isEmpty || !(size > 0)) {
      return 0;
    }
    try {
      return ports.text.width(value, size, weight: weight, tracking: tracking);
    } on StateError {
      // 字体还没就绪（首帧）：宽 0 只会让这一帧的排版贴着锚点，不会抛到绘制栈上。
      return 0;
    }
  }
}

/// [ViewerState] → [ViewerHudState]：只做字段搬运，不做任何推导。
///
/// `item` 是**选中条目**（不是 playingTrack）：Qt 侧查看器读的就是 `m_music->current`
/// （NativeHudDetail.cpp:514），Flutter 侧同一份真值是 `state.song`。
ViewerHudState basicViewerHudState({
  required ViewerState viewer,
  required bool dark,
  String? id,
  String? title,
}) {
  final bool hasItem = id != null || title != null;
  return ViewerHudState(
    item: hasItem ? ViewerHudItem(id: id ?? '', title: title ?? '') : null,
    dark: dark,
    transition: viewer.transition.wire,
    surface: viewer.surface.wire,
    clarity: viewer.clarity,
    targetClarity: viewer.targetClarity,
    resetting: viewer.resetting,
    ready: viewer.ready,
  );
}
