/// 初始化页面：Qt `NativeHudBoot::boot()` 的真实视觉层，同时给 boot_page 提供
/// hudBuilder 的实现，把 glyph 命令（access / logo / auth / welcome / brand / powered）
/// 逐条搬成 HUD 命令流。
///
/// 坐标全部是 Qt 舞台坐标（1920×1080 设计区，横向居中），logical → stage 由宿主负责。
library;

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../hud/protocol/hud_frame.dart';
import '../hud/render/hud_painter.dart';
import '../hud/text/art_run.dart';
import '../hud/text/glyph_font.dart';
import '../ui/pages/boot_page.dart';
import 'basic_hud_resources.dart';

// 1) logo 轮廓（Qt/src/NativeHudBoot.cpp:12-149 的 contour / contourSegment）

/// Qt/src/NativeHudBoot.cpp:16-19 的闭合轮廓（RHINE 的 R 与 H 连成的那条）。
const String _kLogoContour =
    'M295 73C295 41 273 15 240 15C221 15 207 23 192 38C186 43 181 47 176 52C127 96 103 128 70 128C38 128 15 '
    '101 15 70C15 39 37 15 70 15C103 15 127 48 156 75C182 99 208 128 240 128C273 128 295 105 295 73Z';

/// Qt/src/NativeHudBoot.cpp:28-32：逐曲线 512 次采样（不得改小，会影响描边时序）。
const int _kContourSamples = 512;

/// Qt/src/NativeHudBoot.cpp:35-41：与 [_kLogoContour] 里的 C 指令一一对应。
const List<List<double>> _kContourPoints = <List<double>>[
  <double>[295, 41, 273, 15, 240, 15],
  <double>[221, 15, 207, 23, 192, 38],
  <double>[186, 43, 181, 47, 176, 52],
  <double>[127, 96, 103, 128, 70, 128],
  <double>[38, 128, 15, 101, 15, 70],
  <double>[15, 39, 37, 15, 70, 15],
  <double>[103, 15, 127, 48, 156, 75],
  <double>[182, 99, 208, 128, 240, 128],
  <double>[273, 128, 295, 105, 295, 73],
];

/// 一段三次贝塞尔 + 它在整条轮廓上的弧长区间（Qt 的 `ContourPiece`）。
class _ContourPiece {
  _ContourPiece({
    required this.from,
    required this.controlA,
    required this.controlB,
    required this.to,
    required this.begin,
    required this.end,
  });

  final ui.Offset from;
  final ui.Offset controlA;
  final ui.Offset controlB;
  final ui.Offset to;
  final double begin;
  final double end;
}

List<_ContourPiece>? _contourCache;

List<_ContourPiece> _contourPieces() {
  final List<_ContourPiece>? cached = _contourCache;
  if (cached != null) {
    return cached;
  }
  final List<_ContourPiece> pieces = <_ContourPiece>[];
  double accumulated = 0;
  ui.Offset cursor = const ui.Offset(295, 73);
  for (final List<double> points in _kContourPoints) {
    final ui.Offset from = cursor;
    final ui.Offset controlA = ui.Offset(points[0], points[1]);
    final ui.Offset controlB = ui.Offset(points[2], points[3]);
    final ui.Offset to = ui.Offset(points[4], points[5]);
    final double begin = accumulated;
    ui.Offset sampleCursor = cursor;
    for (int sample = 1; sample <= _kContourSamples; sample++) {
      final double t = sample / _kContourSamples;
      final double inverse = 1 - t;
      final ui.Offset next = from * (inverse * inverse * inverse) +
          controlA * (3 * inverse * inverse * t) +
          controlB * (3 * inverse * t * t) +
          to * (t * t * t);
      accumulated += (next - sampleCursor).distance;
      sampleCursor = next;
    }
    pieces.add(_ContourPiece(
      from: from,
      controlA: controlA,
      controlB: controlB,
      to: to,
      begin: begin,
      end: accumulated,
    ));
    cursor = to;
  }
  _contourCache = pieces;
  return pieces;
}

double _contourSize() {
  final List<_ContourPiece> pieces = _contourPieces();
  return pieces.isEmpty ? 0 : pieces.last.end;
}

/// Qt `subContour`：在参数区间 [from, to] 上切出与原曲线几何一致的四点子曲线。
List<ui.Offset> _subContour(_ContourPiece piece, double from, double to) {
  ui.Offset mix(ui.Offset a, ui.Offset b, double t) => a + (b - a) * t;
  final ui.Offset a1 = mix(piece.from, piece.controlA, from);
  final ui.Offset a2 = mix(piece.controlA, piece.controlB, from);
  final ui.Offset a3 = mix(piece.controlB, piece.to, from);
  final ui.Offset b1 = mix(a1, a2, from);
  final ui.Offset b2 = mix(a2, a3, from);
  final ui.Offset head = mix(b1, b2, from);
  final double local = from >= 1 ? 1.0 : (to - from) / (1 - from);
  final ui.Offset d1 = mix(head, b2, local);
  final ui.Offset d2 = mix(b2, a3, local);
  final ui.Offset d3 = mix(a3, piece.to, local);
  final ui.Offset e1 = mix(d1, d2, local);
  final ui.Offset e2 = mix(d2, d3, local);
  return <ui.Offset>[head, d1, e1, mix(e1, e2, local)];
}

String _num(double value) {
  if (value == value.roundToDouble() && value.abs() < 1e15) {
    return value.round().toString();
  }
  return value.toStringAsFixed(6).replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '');
}

/// Qt `contourSegment(startFraction, lengthFraction)`：按绘制进度截取轮廓。
///
/// 输出跨过闭合点的**连续开路径**（Qt/src/NativeHudBoot.cpp:118-126 的注释解释了
/// 为什么不用虚线：起点处两段平头端点会叠出"发丝缝"）。
String _contourSegment(double startFraction, double lengthFraction) {
  if (lengthFraction >= 0.999999) {
    return _kLogoContour;
  }
  final List<_ContourPiece> pieces = _contourPieces();
  final double size = _contourSize();
  if (pieces.isEmpty || size <= 0 || lengthFraction <= 0) {
    return '';
  }
  final double epsilon = 1e-9 * size;
  double begin = (startFraction * size) % size;
  if (begin < 0) {
    begin += size;
  }
  final double end = begin + lengthFraction.clamp(0.0, 1.0) * size;
  final StringBuffer path = StringBuffer();
  for (int lap = 0; lap < 2; lap++) {
    for (final _ContourPiece piece in pieces) {
      final double shift = lap * size;
      final double low = math.max(begin, shift + piece.begin);
      final double high = math.min(end, shift + piece.end);
      final double span = piece.end - piece.begin;
      if (high <= low + epsilon || span <= 0) {
        continue;
      }
      final double from = ((low - shift - piece.begin) / span).clamp(0.0, 1.0);
      final double to = ((high - shift - piece.begin) / span).clamp(0.0, 1.0);
      if (to <= from) {
        continue;
      }
      final List<ui.Offset> points = _subContour(piece, from, to);
      if (path.isEmpty) {
        path.write('M${_num(points[0].dx)} ${_num(points[0].dy)}');
      }
      path.write('C${_num(points[1].dx)} ${_num(points[1].dy)} '
          '${_num(points[2].dx)} ${_num(points[2].dy)} '
          '${_num(points[3].dx)} ${_num(points[3].dy)}');
    }
  }
  return path.toString();
}

// 2) boot glyph 命令流（Qt/src/NativeHudBoot.cpp:155-311 `boot()`）

/// `NativeHud::ink()`：Qt/src/NativeHud.cpp:10-15。
List<Object?> _ink(bool dark) => <Object?>[
      dark ? 0.92 : 0.08,
      dark ? 0.92 : 0.085,
      dark ? 0.92 : 0.075,
      1,
      dark ? 'calibratedWhite' : 'calibratedRGB',
    ];

/// lettering 的排字宽度：Qt `Glyphs::artWidth(key, size, tracking, count)` 的 Dart 版。
///
/// 逐字母 `advance * size + tracking`（lib/hud/text/art_run.dart:118-160 的画笔推进同式）。
double _artWidth(BasicGlyphPorts ports, String key, double size, {double tracking = 0, int count = -1}) {
  final Lettering? lettering = ports.glyphs.letteringFor(key);
  if (lettering == null) {
    return 0;
  }
  final List<LetteringGlyph> letters = count < 0
      ? lettering.letters
      : lettering.letters.take(count).toList(growable: false);
  double width = 0;
  for (final LetteringGlyph letter in letters) {
    width += letter.advance * size + tracking;
  }
  return width;
}

/// 生成 boot 页的 glyph 层命令（背景/白闪/scan 由 boot_page.dart 产出）。
/// [tracks] 提供 Qt 的 logo/brand 曲线；未接线时为 0，不伪造进度。
List<Object?> buildBasicBootCommands({
  required BootFrame frame,
  required double width,
  required BasicGlyphPorts ports,
  required bool dark,
  required BootTrackSource tracks,
}) {
  final List<Object?> commands = <Object?>[];
  // Qt/src/NativeHudBoot.cpp:161 `const auto offset = (width - 1920) / 2;`（水平居中，不缩放）。
  final double shift = (width - kQtDesignWidth) / 2;
  final List<Object?> ink = _ink(dark);
  final double measured = frame.measuredFrame;

  void save() => commands.add(<Object?>['save']);
  void restore() => commands.add(<Object?>['restore']);
  void alpha(double value) => commands.add(<Object?>['alpha', value]);
  void translate(double x, double y) => commands.add(<Object?>['translate', x, y]);
  void scale(double x, double y) => commands.add(<Object?>['scale', x, y]);
  void rotate(double radians) => commands.add(<Object?>['rotate', radians]);
  void text(String value, double x, double y, double size,
      {String weight = 'regular', double tracking = 0, List<Object?>? color}) {
    commands.add(<Object?>['text', value, x, y, size, weight, tracking, color ?? ink]);
  }

  void art(String key, double x, double y, double size,
      {int count = -1, double tracking = 0, List<Object?>? color}) {
    commands.add(<Object?>['art', key, x, y, size, count, tracking, color ?? ink]);
  }

  void fill(double x, double y, double width, double height, List<Object?> color) {
    commands.add(<Object?>['fill', color, x, y, width, height]);
  }

  void path(String data, double penWidth, {List<Object?>? color}) {
    if (data.isEmpty) {
      return;
    }
    commands.add(<Object?>['path', data, penWidth, color ?? ink, <double>[], 0]);
  }

  save();
  translate(shift, 0);

  // :163-167 access：逐字符打出的 "ACCESS PERMISSION REQUIRED"。
  if (frame.accessOpacity > 0) {
    save();
    alpha(frame.accessOpacity);
    art('access', 800, 532, 18, count: frame.accessLetters.length);
    restore();
  }

  // :172-212 logo：轮廓描边 + 符号 + 已打出的字母。
  if (frame.logoOpacity > 0) {
    save();
    alpha(frame.logoOpacity);
    // Qt: translate(518 + logo.offsetX, 463); scale(296/310)，位移来自 logo.leftEdge。
    translate(518 + (tracks.value('logo.leftEdge', measured) - 520), 463);
    scale(296.0 / 310, 296.0 / 310);
    final double cut = tracks.value('logo.movingCut', measured);
    final double start = frame.frame < 420 ? tracks.value('logo.drawStart', measured) : cut + 0.0275;
    final double end = frame.frame < 420 ? tracks.value('logo.drawEnd', measured) : cut + 1;
    final double length = (end - start).clamp(0.0, 1.0);
    path(
      _contourSegment(start, length),
      tracks.value('logo.strokeWidth', measured),
    );
    final double symbolScale = tracks.value('logo.symbolScale', measured);
    if (symbolScale > 0) {
      save();
      translate(tracks.value('logo.plusX', measured), 70);
      rotate(tracks.value('logo.plusAngle', measured) * math.pi / 180);
      scale(symbolScale, symbolScale);
      translate(-69, -70);
      path('M44 70H94M69 45V95', 15);
      restore();
      save();
      translate(tracks.value('logo.minusX', measured), 70);
      scale(symbolScale, symbolScale);
      final double half = tracks.value('logo.minusWidth', measured) / 2;
      path('M${_num(-half)} 0H${_num(half)}', 15);
      restore();
    }
    text(frame.logoLetters, 20, 174 - 16 * 1.044, 16, weight: 'bold', tracking: 22);
    restore();
  }

  // :213-220 auth：'▪' + 逐字母打出的类型化 art。
  if (frame.authOpacity > 0) {
    save();
    alpha(frame.authOpacity);
    text('▪', 907, 528, 14);
    final String auth = frame.authLetters;
    String key = 'processing';
    if (auth.startsWith('ID')) {
      key = 'identity';
    } else if (auth.startsWith('REQUEST')) {
      key = 'request';
    } else if (auth.startsWith(' ')) {
      key = 'processingGlitch';
    }
    const double size = 21.35;
    const double tracking = -0.00909 * 21.35;
    const String prefix = 'ID CONFIRMED : ';
    final int count = key == 'identity' ? math.min(auth.length, prefix.length) : auth.length;
    art(key, 931, 527, size, count: count, tracking: tracking);
    restore();
  }

  // :255-289 welcome：面板 + welcome/company/database art + 欢迎 logo。
  if (frame.welcomeVisible) {
    save();
    alpha(frame.welcomeOpacity);
    translate(960, 552.6);
    scale(frame.welcomeScale, frame.welcomeScale);
    translate(-960, -552.6);
    final List<Object?> panel = List<Object?>.of(ink);
    panel[3] = frame.welcomePanel;
    fill(725, 344, 470, 392, panel);
    final double white = dark ? frame.welcomeInk : 1 - frame.welcomeInk;
    art(
      'welcome',
      960 - _artWidth(ports, 'welcome', 55) / 2,
      403,
      55,
      color: <Object?>[white, white, white, 1, 'calibratedWhite'],
    );
    if (frame.companyVisible) {
      final bool mask = frame.companyMask;
      save();
      alpha(mask ? 0.65 : 1);
      final double companyWidth = _artWidth(ports, 'company', 48, tracking: -0.5);
      art('company', 960 - companyWidth / 2, 475, 48, tracking: -0.5);
      save();
      // :192/:205 highlight = value("highlightKeys", measuredFrame) / 410。
      commands.add(<Object?>[
        'clip',
        755,
        470,
        410 * (tracks.value('highlightKeys', measured) / 410),
        60,
      ]);
      fill(755, 470, 410, 60, ink);
      final List<Object?> highlight = dark
          ? <Object?>[17 / 255, 24 / 255, 27 / 255, 1]
          : <Object?>[238 / 255, 237 / 255, 232 / 255, 1];
      highlight[3] = mask ? 0.06 : 1;
      art('company', 960 - companyWidth / 2, 475, 48, tracking: -0.5, color: highlight);
      restore();
      restore();
    }
    save();
    alpha(frame.databaseOpacity);
    art('database', 960 - _artWidth(ports, 'database', 36) / 2, 537, 36);
    restore();
    if (frame.welcomeLogo) {
      // Qt `logo(858.5, 590, 203)`：同一条静态轮廓（NativeHudBoot.cpp:143-152）。
      save();
      translate(858.5, 590);
      scale(203 / 310, 203 / 310);
      path('M156 75C127 48 103 15 70 15C37 15 15 39 15 70C15 101 38 128 70 128C103 128 127 96 176 52'
          'M155 75C182 99 208 128 240 128C273 128 295 105 295 73C295 41 273 15 240 15C221 15 207 23 192 38',
          26);
      path('M44 70H94M69 45V95M219 70H263', 15);
      restore();
    }
    restore();
  }
  restore();

  // brand：三行，各自的 x 与 opacity 来自曲线。
  for (int index = 0; index < 3; index++) {
    final double local = measured - 278 - index * 2;
    save();
    alpha(tracks.value('brandOpacity', local));
    translate(tracks.value('brandX', local), 0);
    if (index == 0) {
      text('RHINE LAB', 59, 115.425, 50.75, weight: 'bold', tracking: 1);
    } else if (index == 1) {
      text('MUSIC DATABASE', 59, 169, 22, weight: 'demibold', tracking: 1.7);
    } else {
      fill(59, 212, 300, 0.65, ink);
      text('INDEX / COLLECTION / TRACK', 59, 228, 11, tracking: 1.2);
    }
    restore();
  }

  // :301-308 powered：逐字母揭出的 "POWERED BY RHINE LAB"。
  if (frame.poweredLetterCount > 0) {
    save();
    commands.add(<Object?>[
      'clip',
      width - 354,
      945,
      295 * frame.poweredLetterCount / 19,
      35,
    ]);
    text('POWERED BY', width - 354, 947, 19);
    text('RHINE LAB', width - 218, 947, 19, weight: 'bold');
    fill(width - 84, 955, 25, 6, ink);
    restore();
  }
  return commands;
}

/// boot glyph 层：把命令流交给共享 painter（真实 glyph advance / 基线 / art 不偏移）。
class BasicBootGlyphLayer extends StatelessWidget {
  const BasicBootGlyphLayer({
    required this.frame,
    required this.ports,
    required this.dark,
    required this.tracks,
    super.key,
  });

  final BootFrame frame;
  final BasicGlyphPorts ports;
  final bool dark;
  final BootTrackSource tracks;

  @override
  Widget build(BuildContext context) {
    // 页面坐标即 Qt 舞台坐标（1920 设计宽，1080 高），宿主负责 logical→stage 的缩放
    // （与 boot_page.dart 的约定一致），所以这里直接拿布局宽当 Qt 的 width。
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final List<Object?> commands = buildBasicBootCommands(
          frame: frame,
          width: constraints.maxWidth.isFinite ? constraints.maxWidth : kQtDesignWidth,
          ports: ports,
          dark: dark,
          tracks: tracks,
        );
        return IgnorePointer(
          child: CustomPaint(
            painter: HudStagePainter(
              // 与 BasicDiscWarningOverlay 同一套解码方式（只喂命令，不喂 hits）。
              envelope: HudFrameEnvelope.decode(<String, Object?>{
                'generation': 0,
                'frame': const <String, Object?>{},
                'commands': commands,
                'hits': const <Object?>[],
                'state': const <String, Object?>{},
              }),
              // 显式声明舞台：本轮子树已经在 stage 坐标系里（宿主给过一次
              // Transform.scale），命令流本身就是 stage 单位，painter 绝不能再用
              // HudStage.fromLogicalSize 折一次高度（那是 禁止的第二次缩放：
              // 横屏 1080 高恰好等于 1、竖屏 stageHeight≠1080 时会把 glyph 整体缩水）。
              stage: HudStage(
                scale: 1.0,
                width: constraints.maxWidth.isFinite ? constraints.maxWidth : kQtDesignWidth,
                height: constraints.maxHeight.isFinite ? constraints.maxHeight : kQtDesignHeight,
              ),
              ports: HudPainterPorts(
                text: ports.draw,
                // boot 是全站唯一需要 art 图层的页面（logo 符号 / welcome / company /
                // database 都是 lettering 轮廓）；主 HUD 至今没接 art port。
                art: (ui.Canvas canvas, String key, double x, double y, double size, int count,
                    double tracking, ui.Color color) {
                  paintArt(canvas, ports.glyphs, key, x, y, size,
                      count: count, tracking: tracking, color: color);
                },
                path: ports.pathFor,
                image: ports.imageFor,
              ),
            ),
            child: const SizedBox.expand(),
          ),
        );
      },
    );
  }
}

// 3) 页面：门槛层（boot_page.dart）+ glyph 层 + 35s 闸门 / skip 交割

/// 初始化页面：真实门槛页 + glyph 层，交割（35s 到点或 ENTER SYSTEM）回调宿主收页。
///
/// 状态流程与 Qt 一致：`NativeScene` 进入 boot → elapsed 从 1.76 起算 → 35s 硬闸门
/// 切 detail（Qt/src/NativeSceneFrame.cpp:19-21）；skip 直接切 archive
/// （Qt/src/NativeHudController.cpp:682-683）。两条路都经 [onHandoff] 通知宿主收起本页，
/// 宿主随后回到原本所在的相位（详情/资料库），不自动播放、不新建播放器。
class BasicStartupView extends StatefulWidget {
  const BasicStartupView({
    required this.ports,
    required this.dark,
    required this.onHandoff,
    this.tracks,
    this.gateSeconds = kBootGateSeconds,
    super.key,
  });

  final BasicGlyphPorts ports;
  final bool dark;
  final VoidCallback onHandoff;
  final BootTrackSource? tracks;
  final double gateSeconds;

  @override
  State<BasicStartupView> createState() => _BasicStartupViewState();
}

class _BasicStartupViewState extends State<BasicStartupView> {
  late final StopwatchBootClock _clock = StopwatchBootClock();
  late final BootController _controller = BootController(
    clock: _clock,
    tracks: widget.tracks,
    gateSeconds: widget.gateSeconds,
    themeDark: widget.dark,
  );
  bool _handedOff = false;

  @override
  void initState() {
    super.initState();
    _controller.start();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _handoff(BootHandoff handoff) {
    if (_handedOff) {
      return;
    }
    _handedOff = true;
    // 交割只表示"页面看完了"，相位由宿主决定（Qt 的 detail/archive 分别对应详情/资料库）；
    // 这里不碰播放器、不碰队列。
    widget.onHandoff();
  }

  @override
  Widget build(BuildContext context) {
    // 曲线源归 controller 所有（未注入时它自己建 AssetBootTrackSource 并载入
    // Assets/animation/boot-tracks.json）：glyph 层与 scan 层必须看同一份，
    // 否则 logo 描边和扫描弧会各用一套时间。
    final BootTrackSource tracks = _controller.tracks;
    return BootPage(
      controller: _controller,
      clock: _clock,
      tracks: tracks,
      themeDark: widget.dark,
      onHandoff: _handoff,
      hudBuilder: (BuildContext context, BootFrame frame) {
        return BasicBootGlyphLayer(
          frame: frame,
          ports: widget.ports,
          dark: widget.dark,
          tracks: tracks,
        );
      },
    );
  }
}
