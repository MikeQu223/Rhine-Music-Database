import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';

import '../hud/modals/disc_warning_modal.dart';
import '../hud/modals/modal_shell.dart';
import '../hud/modals/settings_modal.dart';
import '../hud/pages/chrome.dart';
import '../hud/protocol/hud_frame.dart';
import '../hud/render/hud_painter.dart';
import '../hud/widgets/settings_row.dart';
import 'basic_hud_resources.dart';
import 'basic_settings.dart';
import 'basic_settings_surface.dart';

/// 收集 op / hit 的 HUD sink（设置浮层的私有实现）。
class BasicSettingsSink implements HudSurfaceSink {
  final List<List<Object?>> commands = <List<Object?>>[];
  final List<HudHit> hits = <HudHit>[];

  @override
  void op(List<Object?> command) => commands.add(command);

  @override
  void hit(HudHit hit) => hits.add(hit);
}

/// ONLY14 设置浮层：模态框架 + 卡片 + 滚动轨道，全部落在 HUD 命令流里。
///
/// 真值来源（逐条对应 Qt）：
/// * 模态几何 / 遮罩 / 面板底 / 标题 / 返回按钮：NativeHudModal.cpp:163-202
///   （[settingsModalBounds] / [paintSettingsModalBackdrop] / [paintSettingsModalFrame]）。
/// * 卡片视口与滚动轨道：NativeHudSettings.cpp:164-165 / :212-224
///   （[SettingsPanelGeometry.viewport] / [scrollTrack] / [scrollUpButton] / [scrollDownButton]）。
/// * 卡片内容：ONLY14 的 14 项（lib/basic/basic_settings_surface.dart 的
///   [BasicSettingsSurface]，自定义区画唱片旋转与当前版本）。
/// * 命中裁剪顺序：先记 chrome 命中，再画卡片，再 [BasicSettingsSurface.clipHits]
///   （`first` 保留 chrome 命中，其余与视口求交）。
///
/// 为什么走"记录 -> 裁剪 -> 重放"：直写 sink 的实现无法回退已发出的 op，
/// 而命中裁剪必须在卡片绘制之后（见 basic_settings_surface.dart 的用法注释）。
class BasicSettingsOverlay extends StatefulWidget {
  const BasicSettingsOverlay({
    super.key,
    required this.stage,
    required this.ports,
    required this.model,
    required this.dark,
    required this.onAction,
    this.scroll = 0,
    this.titleLoopHit = false,
  });

  /// 绘制/命中共用的舞台（竖屏 1080 宽、横屏按 1080 高换算）。
  final HudStage stage;

  /// 真实字形端口：面板文本走它的度量与 fit（与 HUD 其余文字同源）。
  final BasicGlyphPorts ports;

  /// ONLY14 面板模型（行/选项/版本/项目链接都由 [basicSettingsPanelModel] 给出）。
  final BasicSettingsPanelModel model;

  final bool dark;

  /// 非本浮层内部的命中动作（展开、写入、项目链接、唱片旋转…）原样抛给宿主。
  final void Function(String action) onAction;

  /// 初始滚动偏移（stage 像素）。
  final double scroll;

  /// 桌面端标题循环命中（Qt SettingsCard 的 desktopTitleLoopHit）。
  final bool titleLoopHit;

  @override
  State<BasicSettingsOverlay> createState() => BasicSettingsOverlayState();
}

class BasicSettingsOverlayState extends State<BasicSettingsOverlay> {
  double _scroll = 0;
  bool _dragActive = false;

  /// 上一次 build 算出的裁剪后命中表：点击测试与绘制读同一份（不各自推导）。
  List<SettingsHitRegion> _hits = const <SettingsHitRegion>[];

  /// 每一步滚动按钮 / 滚轮的位移：NativeHudInput.cpp:30-33 的 66。
  static const double _wheelStep = SettingsModalMetrics.wheelStep;

  double get scroll => _scroll;

  /// 本帧裁剪后的命中表（只读；点击测试与绘制读同一份）。
  List<SettingsHitRegion> get hits => _hits;

  @override
  void initState() {
    super.initState();
    _scroll = widget.scroll;
  }

  @override
  void didUpdateWidget(covariant BasicSettingsOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 换模型（展开/写入后行高变化）时不能把旧偏移留在越界处：统一 clamp 到新范围。
    final double max = _surface.maximumScroll;
    if (_scroll > max) {
      _scroll = max;
    } else if (_scroll < 0) {
      _scroll = 0;
    }
  }

  Rect get _bounds => settingsModalBounds(widget.stage.width);

  /// 卡片视口：NativeHudSettings.cpp:164-165。
  Rect get _viewport => SettingsPanelGeometry.viewport(
      x: _bounds.left, y: _bounds.top, width: _bounds.width);

  BasicSettingsSurface get _surface => BasicSettingsSurface(
        viewport: _viewport,
        model: widget.model,
        scroll: _scroll,
        dark: widget.dark,
        titleLoopHit: widget.titleLoopHit,
        // fit 走真实字形端口：面板里的长标题按真实字宽截断，而不是原样溢出。
        fit: (String value, double size, double maxWidth, SettingsFontWeight weight) =>
            widget.ports.fit(value, size, maxWidth, settingsFontWeightNames[weight] ?? 'regular'),
      );

  void _scrollBy(double delta) {
    final BasicSettingsSurface surface = _surface;
    final double max = surface.maximumScroll;
    final double next = (_scroll + delta).clamp(0.0, max).toDouble();
    if (next == _scroll) {
      return;
    }
    setState(() => _scroll = next);
  }

  /// 一帧的全部 op / hit（chrome 先、卡片后，命中按视口裁剪）。
  ({List<List<Object?>> commands, List<SettingsHitRegion> hits}) _paintFrame() {
    final SettingsRowRecorder recorder = SettingsRowRecorder();
    final Rect bounds = _bounds;
    final BasicSettingsSurface surface = _surface;
    paintSettingsModalBackdrop(
      width: widget.stage.width,
      bounds: bounds,
      canvas: recorder,
      dark: widget.dark,
    );
    paintSettingsModalFrame(
      x: bounds.left,
      y: bounds.top,
      usable: bounds.width,
      canvas: recorder,
      palette: surface.palette,
      dark: widget.dark,
      fit: surface.fit,
    );
    // 命中分三段，裁剪只作用于中段：
    //   1. chrome（返回按钮）—— 在视口之外，必须原样保留；
    //   2. 卡片行 —— 是唯一会被视口滚出/滚入的部分，交给 clipHits；
    //   3. 轨道 + 两个滚动按钮 —— 在视口右侧，同样必须原样保留。
    // 早先实现把 1/3 也一起 clip 了，结果轨道按钮的命中被裁掉：点它没反应，
    // 而画面照旧画出按钮（假按钮）。
    final int chromeHits = recorder.hits.length;
    surface.paint(recorder);
    final int cardEnd = recorder.hits.length;
    final List<SettingsHitRegion> cardHits =
        surface.clipHits(recorder.hits.sublist(chromeHits));
    _paintRail(recorder, bounds, surface);
    final List<SettingsHitRegion> hits = <SettingsHitRegion>[
      ...recorder.hits.take(chromeHits),
      ...cardHits,
      ...recorder.hits.skip(cardEnd),
    ];
    final List<List<Object?>> commands = <List<Object?>>[];
    final BasicSettingsSink sink = BasicSettingsSink();
    _replay(recorder.ops, BasicSettingsHudCanvas(sink: sink, text: widget.ports, dark: widget.dark));
    commands.addAll(sink.commands);
    return (commands: commands, hits: hits);
  }

  /// 滚动轨道 + thumb + 两个滚动按钮（NativeHudSettings.cpp:212-224）。
  void _paintRail(SettingsRowRecorder recorder, Rect bounds, BasicSettingsSurface surface) {
    final Rect track = SettingsPanelGeometry.scrollTrack(
        x: bounds.left, y: bounds.top, width: bounds.width);
    recorder.fill(track.left, track.top, track.width, track.height,
        SettingsRailMetrics.track(widget.dark));
    final SettingsScrollRail rail = settingsScrollRail(
      track: track,
      contentHeight: surface.contentHeight,
      viewportHeight: _viewport.height,
      offset: surface.clampedScroll,
    );
    if (rail.visible) {
      recorder.fill(rail.thumb.left, rail.thumb.top, rail.thumb.width, rail.thumb.height,
          SettingsRailMetrics.thumb(widget.dark));
    }
    _scrollButton(recorder, surface,
        SettingsPanelGeometry.scrollUpButton(track: track, y: bounds.top),
        SettingsPanelGeometry.scrollUpGlyph, SettingsPanelGeometry.scrollUpAction);
    _scrollButton(recorder, surface,
        SettingsPanelGeometry.scrollDownButton(track: track, y: bounds.top),
        SettingsPanelGeometry.scrollDownGlyph, SettingsPanelGeometry.scrollDownAction);
  }

  void _scrollButton(SettingsRowRecorder recorder, BasicSettingsSurface surface, Rect rect,
      String glyph, String action) {
    recorder.hit(rect.left, rect.top, rect.width, rect.height, action, glyph);
    recorder.fill(rect.left, rect.top, rect.width, rect.height,
        SettingsModalMetrics.modalButtonTint(widget.dark));
    final double inset = SettingsModalMetrics.modalButtonInset(rect.width);
    recorder.text(glyph, rect.left + inset,
        SettingsModalMetrics.modalButtonTextY(rect.top, rect.height, SettingsModalMetrics.scrollButtonTextSize),
        SettingsModalMetrics.scrollButtonTextSize, SettingsFontWeight.regular, 0, surface.palette.ink);
  }

  static void _replay(List<SettingsDrawOp> ops, SettingsCanvas canvas) {
    for (final SettingsDrawOp op in ops) {
      if (op is SettingsFillOp) {
        canvas.fill(op.left, op.top, op.width, op.height, op.color);
      } else if (op is SettingsStrokeOp) {
        canvas.stroke(op.rect, op.color);
      } else if (op is SettingsTextOp) {
        canvas.text(op.value, op.left, op.top, op.size, op.weight, op.tracking, op.color);
      } else if (op is SettingsCenteredOp) {
        canvas.centered(op.value, op.x, op.cy, op.size, op.weight, op.horizontal);
      } else if (op is SettingsCustomOp) {
        canvas.custom(op.renderer, op.body, op.scroll);
      }
    }
  }

  /// 舞台坐标命中：后画者优先（行/按钮压在背景与面板底之上）。
  SettingsHitRegion? _hitAt(Offset stagePoint) {
    final List<SettingsHitRegion> hits = _hits;
    for (int index = hits.length - 1; index >= 0; index--) {
      if (hits[index].rect.contains(stagePoint)) {
        return hits[index];
      }
    }
    return null;
  }

  void _dispatch(String action) {
    if (action == SettingsPanelGeometry.scrollUpAction) {
      _scrollBy(-_wheelStep);
      return;
    }
    if (action == SettingsPanelGeometry.scrollDownAction) {
      _scrollBy(_wheelStep);
      return;
    }
    widget.onAction(action);
  }

  /// 指针位置 -> 舞台坐标（竖屏子树已在舞台单位里 scale=1；横屏逻辑坐标除以 scale）。
  Offset _toStage(Offset local) {
    final double scale = widget.stage.scale > 0 ? widget.stage.scale : 1.0;
    return Offset(local.dx / scale, local.dy / scale);
  }

  @override
  Widget build(BuildContext context) {
    final ({List<List<Object?>> commands, List<SettingsHitRegion> hits}) frame = _paintFrame();
    _hits = frame.hits;
    final HudFrameEnvelope envelope = HudFrameEnvelope.decode(<String, Object?>{
      'generation': 0,
      'frame': <String, Object?>{},
      'commands': frame.commands,
      'hits': const <Object?>[],
      'state': <String, Object?>{},
    });
    return Listener(
      behavior: HitTestBehavior.opaque,
      onPointerSignal: (PointerSignalEvent event) {
        if (event is! PointerScrollEvent) {
          return;
        }
        final Offset point = _toStage(event.localPosition);
        if (!settingsWheelHits(bounds: _bounds, pointerX: point.dx, pointerY: point.dy)) {
          return;
        }
        final BasicSettingsSurface surface = _surface;
        final double next = settingsWheelScroll(
          offset: _scroll,
          contentHeight: surface.contentHeight,
          viewportHeight: _viewport.height,
          steps: event.scrollDelta.dy > 0 ? 1 : (event.scrollDelta.dy < 0 ? -1 : 0),
        );
        if (next != _scroll) {
          setState(() => _scroll = next);
        }
      },
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapUp: (TapUpDetails details) {
          final SettingsHitRegion? hit = _hitAt(_toStage(details.localPosition));
          if (hit != null) {
            _dispatch(hit.action);
          }
        },
        onVerticalDragStart: (DragStartDetails details) {
          _dragActive = _viewport.contains(_toStage(details.localPosition));
        },
        onVerticalDragUpdate: (DragUpdateDetails details) {
          if (!_dragActive) {
            return;
          }
          // 手指上滑（dy < 0）-> 内容向上 -> 偏移增加。除以 scale 换回舞台像素。
          final double scale = widget.stage.scale > 0 ? widget.stage.scale : 1.0;
          _scrollBy(-details.delta.dy / scale);
        },
        onVerticalDragEnd: (DragEndDetails details) => _dragActive = false,
        onVerticalDragCancel: () => _dragActive = false,
        child: Stack(
          fit: StackFit.expand,
          children: <Widget>[
            CustomPaint(
              painter: HudStagePainter(
                envelope: envelope,
                ports: HudPainterPorts(
                  text: widget.ports.draw,
                  path: widget.ports.pathFor,
                  image: widget.ports.imageFor,
                ),
                stage: widget.stage,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 供测试/诊断读取：某个模型在给定舞台上的命中动作集合（不参与绘制）。
List<String> basicSettingsOverlayHitActions(
    HudStage stage, BasicSettingsPanelModel model, bool dark) {
  final Rect bounds = settingsModalBounds(stage.width);
  final BasicSettingsSurface surface = BasicSettingsSurface(
    viewport: SettingsPanelGeometry.viewport(
        x: bounds.left, y: bounds.top, width: bounds.width),
    model: model,
    dark: dark,
  );
  final SettingsRowRecorder recorder = SettingsRowRecorder();
  surface.paint(recorder);
  return <String>[for (final SettingsHitRegion hit in surface.clipHits(recorder.hits)) hit.action];
}

/// 唱片旋转风险确认层（Qt modal id `disc-rotation-warning`，NativeHudController.cpp:711-723）。
///
/// 画面与命中全部来自 [DiscWarningModal] 自己（通用弹层壳：遮罩 + 面板 + 标题 +
/// 四段正文 + 两个按钮），本类只负责：把它的命令流交给 [HudStagePainter] 画出来，
/// 并按 Qt 的命中顺序（append-only，反向遍历）把一次点击翻译成动作串。
///
/// 为什么要单独一层：设置卡片里的“唱片旋转”开关**不直接写偏好**——开启必须先过这张
/// 风险说明（原 Qt 行为），确认后才由 [BasicSettingsRuntime] 写 `on`。
class BasicDiscWarningOverlay extends StatefulWidget {
  const BasicDiscWarningOverlay({
    super.key,
    required this.stage,
    required this.ports,
    required this.dark,
    required this.onAction,
  });

  final HudStage stage;
  final BasicGlyphPorts ports;
  final bool dark;
  final ValueChanged<String> onAction;

  @override
  State<BasicDiscWarningOverlay> createState() => _BasicDiscWarningOverlayState();
}

class _BasicDiscWarningOverlayState extends State<BasicDiscWarningOverlay> {
  List<HudHit> _hits = const <HudHit>[];

  Offset _toStage(Offset local) {
    final double scale = widget.stage.scale > 0 ? widget.stage.scale : 1.0;
    return Offset(local.dx / scale, local.dy / scale);
  }

  String? _hitAt(Offset stagePoint) {
    final List<HudHit> hits = _hits;
    for (int index = hits.length - 1; index >= 0; index--) {
      final HudHit hit = hits[index];
      if (Rect.fromLTWH(hit.x, hit.y, hit.width, hit.height).contains(stagePoint)) {
        return hit.action;
      }
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final BasicSettingsSink sink = BasicSettingsSink();
    final ModalShellResult result = DiscWarningModal(
      width: widget.stage.width,
      dark: widget.dark,
    ).build(sink, widget.ports);
    _hits = result.hits;
    final HudFrameEnvelope envelope = HudFrameEnvelope.decode(<String, Object?>{
      'generation': 0,
      'frame': <String, Object?>{},
      'commands': sink.commands,
      'hits': const <Object?>[],
      'state': <String, Object?>{},
    });
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapUp: (TapUpDetails details) {
        final String? action = _hitAt(_toStage(details.localPosition));
        if (action != null) {
          widget.onAction(action);
        }
      },
      child: CustomPaint(
        painter: HudStagePainter(
          envelope: envelope,
          ports: HudPainterPorts(
            text: widget.ports.draw,
            path: widget.ports.pathFor,
            image: widget.ports.imageFor,
          ),
          stage: widget.stage,
        ),
        child: const SizedBox.expand(),
      ),
    );
  }
}
