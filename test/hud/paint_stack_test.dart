// T30-C18 render atom tests, WRITTEN BUT NOT EXECUTED
//
// Atom STACK: lib/hud/render/paint_stack.dart.
// This atom forbids flutter/dart test, analyze, build and codegen, so RED and
// GREEN are both unverified here. Every expectation below was derived by reading
// the Qt source cited beside it and the painter code, never by running a binary.
//
// Qt authority per expectation:
//   Qt/src/Glyphs.cpp:637-829  dispatch chain (op name in element 0, flat array)
//   Qt/src/Glyphs.cpp:530-564  text body: translate(x, y + size * 1.044),
//                              scale(size / 1000, -size / 1000)
//   Qt/src/Glyphs.cpp:565-588  art body: translate(x, y), scale(size / 1000, size / 1000)
//   Qt/src/Glyphs.cpp:738-760  path: FlatCap + MiterJoin, dash / qMax(penWidth, .0001)
//   Qt/src/Glyphs.cpp:761-774  arc: RoundCap, rect(cx - r, cy - r, 2r, 2r)
//   Qt/src/Glyphs.cpp:775-805  right-mask: 16 smoothstep stops, rect(start, 0, right - start, h)
//   Qt/src/Glyphs.cpp:806-812  gradient: fixed centre (979.2, 518.4), radius 1100
//   Qt/src/Glyphs.cpp:813-824  image: drawImage only when the raster is non-null
//   Qt/src/NativeHudBoot.cpp:358-369  publication of arc angles as (cos, +sin)
//   third_party/qt/qtbase/src/gui/painting/qpen.cpp:100-101, :487-490, :502-515
//   third_party/qt/qtbase/src/gui/painting/qstroker.cpp:1072-1115

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:rhine_music_database/hud/protocol/hud_command.dart';
import 'package:rhine_music_database/hud/render/clip_alpha.dart';
import 'package:rhine_music_database/hud/render/gradient_mask.dart';
import 'package:rhine_music_database/hud/render/paint_stack.dart';

/// The 17 op arrays in the frozen wire shape (`Qt/src/Glyphs.cpp:637-829`):
/// a flat array per command, element 0 is the op name, no envelope, no id.
List<Object?> frozenWireFixture() => <Object?>[
      <Object?>['save'],
      <Object?>['translate', 10, 20],
      <Object?>['scale', 2, 3],
      <Object?>['rotate', 0.5],
      <Object?>['alpha', 0.5],
      <Object?>['clip', 1, 2, 30, 40],
      <Object?>[
        'fill',
        <Object?>[1, 1, 1, 1],
        5,
        6,
        7,
        8,
      ],
      <Object?>[
        'ellipse',
        <Object?>[1, 1, 1, 1],
        9,
        10,
        11,
        12,
      ],
      <Object?>[
        'text',
        'T30',
        100,
        200,
        26.5,
        'medium',
        1.5,
        <Object?>[1, 1, 1, 1],
      ],
      <Object?>[
        'art',
        'permission',
        300,
        400,
        26.5,
        -1,
        0.0,
        <Object?>[1, 1, 1, 1],
      ],
      <Object?>['fill-path', 'panel', <Object?>[1, 1, 1, 1]],
      <Object?>[
        'path',
        'ring',
        2.0,
        <Object?>[1, 1, 1, 1],
        <Object?>[6, 3],
        4,
      ],
      <Object?>[
        'arc',
        960,
        540,
        200,
        0.5,
        1.0,
        2.4,
        <Object?>[1, 1, 1, 1],
      ],
      <Object?>[
        'right-mask',
        <Object?>[1, 1, 1, 0.5],
        100,
        200,
        400,
        1080,
      ],
      <Object?>['gradient', true],
      <Object?>['image', 'stage', 0, 0, 1920, 1080],
      <Object?>['restore'],
    ];

/// One wire command, decoded exactly like the runtime pipeline does it.
HudCommand onlyCommand(List<Object?> wire) =>
    decodeHudCommands(<Object?>[wire]).commands.single;

/// A decoded wire stream (`T03` decoder, already covered by hud_frame_test).
List<HudCommand> wireStream(List<Object?> wire) =>
    decodeHudCommands(wire).commands;

/// Straight horizontal line of [length] logical units, used for dash geometry.
ui.Path horizontalLine(double length) => ui.Path()
  ..moveTo(0, 0)
  ..lineTo(length, 0);

/// Lengths of the drawn contours: one entry per dash of a dashed path.
List<double> dashSegmentLengths(ui.Path path) {
  final List<double> lengths = <double>[];
  for (final ui.PathMetric metric in path.computeMetrics()) {
    lengths.add(metric.length);
  }
  return lengths;
}

/// Recording stand-in for `ui.Canvas`: proves which Flutter call each op makes,
/// without a rasteriser and without running the engine.
class _RecordingCanvas implements ui.Canvas {
  final List<String> calls = <String>[];
  final List<ui.Rect> rects = <ui.Rect>[];
  final List<ui.Paint> paints = <ui.Paint>[];
  final List<ui.Path> paths = <ui.Path>[];
  final List<ui.Rect> clips = <ui.Rect>[];
  final List<bool> clipAntiAlias = <bool>[];
  final List<ui.Offset> translations = <ui.Offset>[];
  final List<ui.Offset> scales = <ui.Offset>[];
  final List<double> rotations = <double>[];
  final List<ui.Image> images = <ui.Image>[];
  int saveCount = 0;
  int restoreCount = 0;
  int layerCount = 0;

  int get rectDraws => calls.where((String c) => c == 'drawRect').length;
  int get ovalDraws => calls.where((String c) => c == 'drawOval').length;
  int get pathDraws => calls.where((String c) => c == 'drawPath').length;
  int get imageDraws => calls.where((String c) => c == 'drawImageRect').length;

  @override
  void save() {
    saveCount++;
    calls.add('save');
  }

  @override
  void restore() {
    restoreCount++;
    calls.add('restore');
  }

  @override
  void saveLayer(ui.Rect? bounds, ui.Paint paint) {
    layerCount++;
    saveCount++;
    paints.add(paint);
    calls.add('saveLayer');
  }

  @override
  void translate(double dx, double dy) {
    translations.add(ui.Offset(dx, dy));
    calls.add('translate');
  }

  @override
  void scale(double sx, [double? sy]) {
    scales.add(ui.Offset(sx, sy ?? sx));
    calls.add('scale');
  }

  @override
  void rotate(double radians) {
    rotations.add(radians);
    calls.add('rotate');
  }

  @override
  void clipRect(ui.Rect rect, {ui.ClipOp clipOp = ui.ClipOp.intersect, bool doAntiAlias = true}) {
    clips.add(rect);
    clipAntiAlias.add(doAntiAlias);
    calls.add('clipRect');
  }

  @override
  void drawRect(ui.Rect rect, ui.Paint paint) {
    rects.add(rect);
    paints.add(paint);
    calls.add('drawRect');
  }

  @override
  void drawOval(ui.Rect rect, ui.Paint paint) {
    rects.add(rect);
    paints.add(paint);
    calls.add('drawOval');
  }

  @override
  void drawPath(ui.Path path, ui.Paint paint) {
    paths.add(path);
    paints.add(paint);
    calls.add('drawPath');
  }

  @override
  void drawImageRect(ui.Image image, ui.Rect src, ui.Rect dst, ui.Paint paint) {
    images.add(image);
    rects.add(dst);
    paints.add(paint);
    calls.add('drawImageRect');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) {
    calls.add('other:${invocation.memberName}');
    return null;
  }
}

void main() {
  group('frozen 17-op wire fixture', () {
    testWidgets('paints every op in order, without issues, without reordering',
        (WidgetTester tester) async {
      final ui.Image stage = await createTestImage(width: 4, height: 4);
      final List<Object?> wire = frozenWireFixture();
      expect(wire.length, 17);
      expect(hudKnownOperationNames.length, 17);

      final HudCommandDecode decoded = decodeHudCommands(wire);
      expect(decoded.issues, isEmpty);
      expect(decoded.commands.length, 17);

      final List<HudCommand> before = List<HudCommand>.of(decoded.commands);
      // Unmodifiable on purpose: a sort or an in-place edit would throw.
      final List<HudCommand> order = List<HudCommand>.unmodifiable(decoded.commands);

      final _RecordingCanvas canvas = _RecordingCanvas();
      final List<List<Object>> textCalls = <List<Object>>[];
      final List<List<Object>> artCalls = <List<Object>>[];
      final List<String> pathKeys = <String>[];
      final List<String> imageKeys = <String>[];

      final HudPaintResult result = paintHudCommands(
        canvas: canvas,
        commands: order,
        text: (ui.Canvas c, String value, double x, double y, double size,
            String weight, double tracking, ui.Color color) {
          textCalls.add(<Object>[value, x, y, size, weight, tracking, color]);
        },
        art: (ui.Canvas c, String key, double x, double y, double size,
            int count, double tracking, ui.Color color) {
          artCalls.add(<Object>[key, x, y, size, count, tracking, color]);
        },
        path: (String key) {
          pathKeys.add(key);
          return horizontalLine(100);
        },
        image: (String key) {
          imageKeys.add(key);
          return stage;
        },
      );

      expect(result.issues, isEmpty);
      expect(result.hasIssues, isFalse);
      expect(result.state.depth, 0);
      expect(result.state.isBalanced, isTrue);
      expect(result.state.hasClip, isFalse);

      // quantity and order untouched, same objects, same positions
      expect(decoded.commands.length, 17);
      for (int i = 0; i < before.length; i++) {
        expect(identical(decoded.commands[i], before[i]), isTrue);
      }

      expect(pathKeys, <String>['panel', 'ring']);
      expect(imageKeys, <String>['stage']);
      expect(textCalls.length, 1);
      expect(textCalls.single[0], 'T30');
      expect(artCalls.length, 1);
      expect(artCalls.single[0], 'permission');

      expect(canvas.translations.single, const ui.Offset(10, 20));
      expect(canvas.scales.single, const ui.Offset(2, 3));
      expect(canvas.rotations.single, 0.5);
      expect(canvas.clips.single, ui.Rect.fromLTWH(1, 2, 30, 40));
      expect(canvas.clipAntiAlias.single, isFalse);
      expect(canvas.rectDraws, 3);
      expect(canvas.ovalDraws, 1);
      expect(canvas.pathDraws, 3);
      expect(canvas.imageDraws, 1);
      // 1 wire save + 1 clip save + 1 gradient layer, each popped again
      expect(canvas.saveCount, 3);
      expect(canvas.restoreCount, 3);
      expect(canvas.layerCount, 1);
    });
  });

  group('op by op against Qt/src/Glyphs.cpp', () {
    test('save then restore keeps canvas and state balanced (Glyphs.cpp:644-652)', () {
      final _RecordingCanvas canvas = _RecordingCanvas();
      final HudPaintResult result = paintHudCommands(
        canvas: canvas,
        commands: wireStream(<Object?>[
          <Object?>['save'],
          <Object?>['restore'],
        ]),
      );
      expect(result.issues, isEmpty);
      expect(result.state.depth, 0);
      expect(result.state.isBalanced, isTrue);
      expect(canvas.saveCount, 1);
      expect(canvas.restoreCount, 1);
    });

    test('restore without save records unbalancedRestore and leaves the canvas alone', () {
      final _RecordingCanvas canvas = _RecordingCanvas();
      final HudPaintResult result = paintHudCommands(
        canvas: canvas,
        commands: wireStream(<Object?>[
          <Object?>['restore'],
        ]),
      );
      expect(result.issues.length, 1);
      final HudPaintIssue issue = result.issues.single;
      expect(issue.kind, HudPaintIssueKind.unbalancedRestore);
      expect(issue.op, 'restore');
      expect(issue.index, 0);
      // Qt only warns (Glyphs.cpp:651-652); the canvas must not be popped.
      expect(canvas.restoreCount, 0);
      expect(canvas.saveCount, 0);
      expect(result.state.depth, 0);
      expect(result.state.opacity, 1.0);
      expect(result.state.hasClip, isFalse);
    });

    test('alpha multiplies the accumulated opacity (Glyphs.cpp:658-659)', () {
      final _RecordingCanvas canvas = _RecordingCanvas();
      final HudPaintResult result = paintHudCommands(
        canvas: canvas,
        commands: wireStream(<Object?>[
          <Object?>['alpha', 0.5],
          <Object?>['alpha', 0.5],
          <Object?>[
            'fill',
            <Object?>[1, 1, 1, 0.5],
            0,
            0,
            10,
            10,
          ],
        ]),
      );
      expect(result.issues, isEmpty);
      expect(result.state.opacity, closeTo(0.25, 1e-12));
      // the painter opacity reaches the paint, not just the bookkeeping
      expect(canvas.paints.single.color.a, closeTo(0.125, 1e-6));
    });

    test('translate maps to Canvas.translate(n(1), n(2)) (Glyphs.cpp:660-661)', () {
      final _RecordingCanvas canvas = _RecordingCanvas();
      paintHudCommands(
        canvas: canvas,
        commands: wireStream(<Object?>[
          <Object?>['translate', 12.5, -3.25],
        ]),
      );
      expect(canvas.translations.single, const ui.Offset(12.5, -3.25));
    });

    test('scale maps to Canvas.scale(n(1), n(2)) (Glyphs.cpp:666-667)', () {
      final _RecordingCanvas canvas = _RecordingCanvas();
      paintHudCommands(
        canvas: canvas,
        commands: wireStream(<Object?>[
          <Object?>['scale', 2.5, 0.5],
        ]),
      );
      expect(canvas.scales.single, const ui.Offset(2.5, 0.5));
    });

    test('rotate passes the wire radians through (Glyphs.cpp:671-672)', () {
      final _RecordingCanvas canvas = _RecordingCanvas();
      paintHudCommands(
        canvas: canvas,
        commands: wireStream(<Object?>[
          <Object?>['rotate', 1.25],
        ]),
      );
      // Qt rotates by n(1) * 180 / pi degrees; Flutter rotates by radians and
      // both are clockwise-positive in the y-down space (painting.dart:7045),
      // so the wire value is neither converted again nor inverted.
      expect(canvas.rotations.single, 1.25);
    });

    test('clip saves and intersects like Qt::IntersectClip (Glyphs.cpp:676-678)', () {
      final _RecordingCanvas canvas = _RecordingCanvas();
      final HudPaintResult result = paintHudCommands(
        canvas: canvas,
        commands: wireStream(<Object?>[
          <Object?>['save'],
          <Object?>['clip', 10, 20, 100, 200],
          <Object?>['clip', 10, 20, 50, 400],
        ]),
      );
      expect(result.issues, isEmpty);
      expect(canvas.clips.length, 2);
      expect(canvas.clips.first, ui.Rect.fromLTWH(10, 20, 100, 200));
      expect(canvas.clips.last, ui.Rect.fromLTWH(10, 20, 50, 400));
      expect(canvas.clipAntiAlias, <bool>[false, false]);
      // IntersectClip: the visible clip is the intersection of both rects.
      expect(
        result.state.clip,
        intersectHudClip(
          ui.Rect.fromLTWH(10, 20, 100, 200),
          ui.Rect.fromLTWH(10, 20, 50, 400),
        ),
      );
      expect(result.state.clip, ui.Rect.fromLTWH(10, 20, 50, 200));
    });

    test('clip is undone by the enclosing restore (Qt painter state)', () {
      final _RecordingCanvas canvas = _RecordingCanvas();
      final HudPaintResult result = paintHudCommands(
        canvas: canvas,
        commands: wireStream(<Object?>[
          <Object?>['save'],
          <Object?>['clip', 1, 2, 30, 40],
          <Object?>['restore'],
        ]),
      );
      expect(result.issues, isEmpty);
      expect(result.state.hasClip, isFalse);
      expect(result.state.depth, 0);
      expect(canvas.saveCount, 2);
      expect(canvas.restoreCount, 2);
      expect(canvas.calls, <String>['save', 'save', 'clipRect', 'restore', 'restore']);
    });

    test('fill draws the wire rect with a fill paint (Glyphs.cpp:684-691)', () {
      final _RecordingCanvas canvas = _RecordingCanvas();
      final HudPaintResult result = paintHudCommands(
        canvas: canvas,
        commands: wireStream(<Object?>[
          <Object?>[
            'fill',
            <Object?>[1, 1, 1, 1],
            5,
            6,
            7,
            8,
          ],
        ]),
      );
      expect(result.issues, isEmpty);
      expect(canvas.rects.single, ui.Rect.fromLTWH(5, 6, 7, 8));
      expect(canvas.paints.single.style, ui.PaintingStyle.fill);
      expect(canvas.paints.single.color.a, 1.0);
    });

    test('ellipse fills and never strokes (Glyphs.cpp:692-701)', () {
      final _RecordingCanvas canvas = _RecordingCanvas();
      final HudPaintResult result = paintHudCommands(
        canvas: canvas,
        commands: wireStream(<Object?>[
          <Object?>[
            'ellipse',
            <Object?>[1, 1, 1, 1],
            9,
            10,
            11,
            12,
          ],
        ]),
      );
      expect(result.issues, isEmpty);
      expect(canvas.ovalDraws, 1);
      expect(canvas.rects.single, ui.Rect.fromLTWH(9, 10, 11, 12));
      expect(canvas.paints.single.style, ui.PaintingStyle.fill);
      expect(canvas.pathDraws, 0);
    });

    test('text forwards the wire tuple and leaves the 1.044 baseline to the port', () {
      final _RecordingCanvas canvas = _RecordingCanvas();
      final List<List<Object>> calls = <List<Object>>[];
      final HudPaintResult result = paintHudCommands(
        canvas: canvas,
        commands: wireStream(<Object?>[
          <Object?>[
            'text',
            'T30',
            100,
            200,
            26.5,
            'medium',
            1.5,
            <Object?>[1, 1, 1, 1],
          ],
        ]),
        text: (ui.Canvas c, String value, double x, double y, double size,
            String weight, double tracking, ui.Color color) {
          calls.add(<Object>[value, x, y, size, weight, tracking, color]);
        },
      );
      expect(result.issues, isEmpty);
      expect(calls.single[0], 'T30');
      expect(calls.single[1], 100.0);
      // Glyphs.cpp:536 adds size * 1.044 inside the text body, i.e. in the port,
      // so the painter must hand over the raw wire y.
      expect(calls.single[2], 200.0);
      expect(calls.single[3], 26.5);
      expect(calls.single[4], 'medium');
      expect(calls.single[5], 1.5);
      expect((calls.single[6] as ui.Color).a, 1.0);
    });

    test('text without a port records missingTextPort (never silent)', () {
      final _RecordingCanvas canvas = _RecordingCanvas();
      final HudPaintResult result = paintHudCommands(
        canvas: canvas,
        commands: wireStream(<Object?>[
          <Object?>['text', 'T30', 0, 0, 20, 'regular', 0, <Object?>[1, 1, 1, 1]],
        ]),
      );
      expect(result.issues.single.kind, HudPaintIssueKind.missingTextPort);
      expect(result.issues.single.op, 'text');
      expect(canvas.calls, isEmpty);
    });

    test('art forwards key and count without a baseline shift (Glyphs.cpp:565-588)', () {
      final _RecordingCanvas canvas = _RecordingCanvas();
      final List<List<Object>> calls = <List<Object>>[];
      final HudPaintResult result = paintHudCommands(
        canvas: canvas,
        commands: wireStream(<Object?>[
          <Object?>[
            'art',
            'permission',
            300,
            400,
            26.5,
            -1,
            0.5,
            <Object?>[1, 1, 1, 1],
          ],
        ]),
        art: (ui.Canvas c, String key, double x, double y, double size,
            int count, double tracking, ui.Color color) {
          calls.add(<Object>[key, x, y, size, count, tracking, color]);
        },
      );
      expect(result.issues, isEmpty);
      expect(calls.single[0], 'permission');
      expect(calls.single[1], 300.0);
      // art scales from (x, y) with no 1.044 factor (Glyphs.cpp:572-573)
      expect(calls.single[2], 400.0);
      expect(calls.single[3], 26.5);
      // a[5].toInt(-1): -1 means the whole string, and it survives the port
      expect(calls.single[4], -1);
      expect(calls.single[5], 0.5);
    });

    test('art without a port records missingArtPort (never silent)', () {
      final _RecordingCanvas canvas = _RecordingCanvas();
      final HudPaintResult result = paintHudCommands(
        canvas: canvas,
        commands: wireStream(<Object?>[
          <Object?>['art', 'permission', 0, 0, 20, -1, 0, <Object?>[1, 1, 1, 1]],
        ]),
      );
      expect(result.issues.single.kind, HudPaintIssueKind.missingArtPort);
      expect(result.issues.single.op, 'art');
    });

    test('fill-path fills the looked-up path (Glyphs.cpp:728-737)', () {
      final _RecordingCanvas canvas = _RecordingCanvas();
      final HudPaintResult result = paintHudCommands(
        canvas: canvas,
        commands: wireStream(<Object?>[
          <Object?>['fill-path', 'panel', <Object?>[1, 1, 1, 1]],
        ]),
        path: (String key) => horizontalLine(42),
      );
      expect(result.issues, isEmpty);
      expect(canvas.pathDraws, 1);
      expect(canvas.paints.single.style, ui.PaintingStyle.fill);
      expect(dashSegmentLengths(canvas.paths.single).single, closeTo(42, 1e-6));
    });

    test('fill-path with an unknown key records missingPath', () {
      final _RecordingCanvas canvas = _RecordingCanvas();
      final HudPaintResult result = paintHudCommands(
        canvas: canvas,
        commands: wireStream(<Object?>[
          <Object?>['fill-path', 'ghost', <Object?>[1, 1, 1, 1]],
        ]),
        path: (String key) => null,
      );
      expect(result.issues.single.kind, HudPaintIssueKind.missingPath);
      expect(result.issues.single.op, 'fill-path');
      expect(canvas.calls, isEmpty);
    });

    test('path strokes with FlatCap + MiterJoin (Glyphs.cpp:748-760)', () {
      final _RecordingCanvas canvas = _RecordingCanvas();
      final HudPaintResult result = paintHudCommands(
        canvas: canvas,
        commands: wireStream(<Object?>[
          <Object?>['path', 'ring', 2.0, <Object?>[1, 1, 1, 1]],
        ]),
        path: (String key) => horizontalLine(50),
      );
      expect(result.issues, isEmpty);
      final ui.Paint paint = canvas.paints.single;
      expect(paint.style, ui.PaintingStyle.stroke);
      expect(paint.strokeWidth, 2.0);
      expect(paint.strokeCap, ui.StrokeCap.butt);
      expect(paint.strokeJoin, ui.StrokeJoin.miter);
      // no dash -> the looked-up path is stroked unchanged
      expect(dashSegmentLengths(canvas.paths.single).single, closeTo(50, 1e-6));
    });

    test('path with a dash uses the wire lengths as device lengths (Glyphs.cpp:751-756)', () {
      final _RecordingCanvas canvas = _RecordingCanvas();
      final HudPaintResult result = paintHudCommands(
        canvas: canvas,
        commands: wireStream(<Object?>[
          <Object?>['path', 'ring', 3.0, <Object?>[1, 1, 1, 1], <Object?>[6, 3], 4],
        ]),
        path: (String key) => horizontalLine(100),
      );
      expect(result.issues, isEmpty);
      final List<double> segments = dashSegmentLengths(canvas.paths.single);
      // penWidth 3, wire dash 6/3 and wire offset 4 stay 6/3/4 on device: the
      // offset eats 4 of the first 6, so the first dash is 2 and the next are 6.
      expect(segments.first, closeTo(2.0, 1e-6));
      expect(segments[1], closeTo(6.0, 1e-6));
      expect(segments.length, 12);
      expect(segments.last, closeTo(5.0, 1e-6));
    });

    test('arc strokes RoundCap + BevelJoin on the Qt rect (Glyphs.cpp:761-774)', () {
      final _RecordingCanvas canvas = _RecordingCanvas();
      final HudPaintResult result = paintHudCommands(
        canvas: canvas,
        commands: wireStream(<Object?>[
          <Object?>[
            'arc',
            100,
            100,
            50,
            0.0,
            math.pi / 2,
            2.5,
            <Object?>[1, 1, 1, 1],
          ],
          <Object?>[
            'arc',
            100,
            100,
            50,
            0.5,
            0.25,
            2.5,
            <Object?>[1, 1, 1, 1],
          ],
        ]),
      );
      expect(result.issues, isEmpty);
      for (final ui.Paint paint in canvas.paints) {
        expect(paint.style, ui.PaintingStyle.stroke);
        expect(paint.strokeWidth, 2.5);
        expect(paint.strokeCap, ui.StrokeCap.round);
        expect(paint.strokeJoin, ui.StrokeJoin.bevel);
      }
      final ui.PathMetric first = canvas.paths.first.computeMetrics().single;
      // start 0 -> 3 o'clock, sweep +pi/2 -> 6 o'clock: the wire angles are
      // already y-down clockwise, which is Flutter's arc convention.
      final ui.Tangent start0 = first.getTangentForOffset(0)!;
      expect(start0.position.dx, closeTo(150, 1e-6));
      expect(start0.position.dy, closeTo(100, 1e-6));
      final ui.Tangent end0 = first.getTangentForOffset(first.length - 1e-9)!;
      expect(end0.position.dx, closeTo(100, 1e-6));
      expect(end0.position.dy, closeTo(150, 1e-6));
      final ui.PathMetric second = canvas.paths.last.computeMetrics().single;
      final ui.Tangent start1 = second.getTangentForOffset(0)!;
      expect(start1.position.dx, closeTo(100 + 50 * math.cos(0.5), 1e-6));
      expect(start1.position.dy, closeTo(100 + 50 * math.sin(0.5), 1e-6));
    });

    test('right-mask fills (start, 0, right - start, height) with the 16-step mask',
        () {
      final _RecordingCanvas canvas = _RecordingCanvas();
      final HudPaintResult result = paintHudCommands(
        canvas: canvas,
        commands: wireStream(<Object?>[
          <Object?>['right-mask', <Object?>[1, 1, 1, 1], 100, 200, 400, 1080],
        ]),
      );
      expect(result.issues, isEmpty);
      // Glyphs.cpp:805 QRectF(start, 0, n(4) - start, n(5))
      expect(canvas.rects.single, ui.Rect.fromLTWH(100, 0, 300, 1080));
      expect(canvas.paints.single.shader, isNotNull);
      expect(canvas.paints.single.shader, isA<ui.Gradient>());
      // 16 segments = 17 stops, smoothstep eased (gradient_mask.dart)
      expect(hudRightMaskSteps, 16);
      expect(hudRightMaskStopColors(const ui.Color(0xFFFFFFFF)).length, 17);
      expect(hudRightMaskEase(0.5), 0.5);
    });

    test('gradient fills the fixed centre rect with the frozen radial (Glyphs.cpp:806-812)',
        () {
      final _RecordingCanvas canvas = _RecordingCanvas();
      final HudPaintResult result = paintHudCommands(
        canvas: canvas,
        commands: wireStream(<Object?>[
          <Object?>['gradient', false],
          <Object?>['gradient', true],
        ]),
      );
      expect(result.issues, isEmpty);
      expect(canvas.rects, <ui.Rect>[hudBackgroundGradientRect, hudBackgroundGradientRect]);
      expect(canvas.paints.every((ui.Paint p) => p.shader is ui.Gradient), isTrue);
      // the centre does not move: the op only carries the dark flag
      expect(hudBackgroundGradientCenterX, 979.2);
      expect(hudBackgroundGradientCenterY, 518.4);
      expect(hudBackgroundGradientRadius, 1100);
      expect(hudBackgroundGradientStops, <double>[0, 0.76, 1]);
      expect(hudBackgroundGradientRect, ui.Rect.fromLTWH(-4096, -4096, 8192, 8192));
    });

    test('gradient below full opacity composites through a layer', () {
      final _RecordingCanvas canvas = _RecordingCanvas();
      final HudPaintResult result = paintHudCommands(
        canvas: canvas,
        commands: wireStream(<Object?>[
          <Object?>['alpha', 0.5],
          <Object?>['gradient', false],
        ]),
      );
      expect(result.issues, isEmpty);
      expect(canvas.layerCount, 1);
      expect(canvas.saveCount, 1);
      expect(canvas.restoreCount, 1);
    });

    testWidgets('image draws into the wire rect and records a missing raster',
        (WidgetTester tester) async {
      final ui.Image stage = await createTestImage(width: 4, height: 4);
      final _RecordingCanvas canvas = _RecordingCanvas();
      final HudPaintResult drawn = paintHudCommands(
        canvas: canvas,
        commands: wireStream(<Object?>[
          <Object?>['image', 'stage', 0, 0, 1920, 1080],
        ]),
        image: (String key) => stage,
      );
      expect(drawn.issues, isEmpty);
      expect(canvas.rects.single, ui.Rect.fromLTWH(0, 0, 1920, 1080));
      expect(canvas.images.single, same(stage));
      expect(canvas.paints.single.color.a, 1.0);

      final _RecordingCanvas missing = _RecordingCanvas();
      final HudPaintResult skipped = paintHudCommands(
        canvas: missing,
        commands: wireStream(<Object?>[
          <Object?>['image', 'stage', 0, 0, 1920, 1080],
        ]),
        image: (String key) => null,
      );
      expect(skipped.issues.single.kind, HudPaintIssueKind.missingImage);
      expect(missing.calls, isEmpty);

      final _RecordingCanvas portless = _RecordingCanvas();
      final HudPaintResult noPort = paintHudCommands(
        canvas: portless,
        commands: wireStream(<Object?>[
          <Object?>['image', 'stage', 0, 0, 1920, 1080],
        ]),
      );
      expect(noPort.issues.single.kind, HudPaintIssueKind.missingImage);
      expect(noPort.issues.single.detail, contains('port'));
    });
  });

  group('dash law: device length equals the wire original', () {
    test('normalizeHudDashPattern divides by one pen width', () {
      expect(normalizeHudDashPattern(<double>[6, 3], 3), <double>[2, 1]);
      expect(normalizeHudDashPattern(<double>[6, 3], 1), <double>[6, 3]);
    });

    test('normalizeHudDashOffset divides by one pen width', () {
      expect(normalizeHudDashOffset(4, 2), 2);
      expect(normalizeHudDashOffset(4, 1), 4);
    });

    test('a zero pen width falls back to the 0.0001 floor (Glyphs.cpp:752)', () {
      expect(normalizeHudDashPattern(<double>[6], 0).single, closeTo(60000, 1e-6));
      // multiplying back by the same floor restores the wire value
      expect(
        normalizeHudDashPattern(<double>[6], 0).single * 0.0001,
        closeTo(6, 1e-9),
      );
    });

    test('dashHudPath consumes device-absolute lengths (penWidth 3, wire 6/3/4)', () {
      final ui.Path line = horizontalLine(100);
      // dividing then multiplying back by one pen width is the identity, so the
      // device pattern of wire 6/3 with penWidth 3 is exactly 6/3 ...
      final List<double> device = normalizeHudDashPattern(<double>[6, 3], 3)
          .map((double value) => value * 3)
          .toList();
      expect(device, <double>[6, 3]);
      final double deviceOffset = normalizeHudDashOffset(4, 3) * 3;
      expect(deviceOffset, closeTo(4, 1e-9));

      final List<double> segments =
          dashSegmentLengths(dashHudPath(line, device, deviceOffset));
      expect(segments.first, closeTo(2.0, 1e-6));
      expect(segments[1], closeTo(6.0, 1e-6));

      // counterexample: the same stream with the values divided a second time
      // would draw 1 instead of 2 - the defect this law exists to prevent.
      final List<double> doubleDivided = dashSegmentLengths(
        dashHudPath(line, <double>[2, 1], 4),
      );
      expect(doubleDivided.first, closeTo(1.0, 1e-6));
      expect(doubleDivided.first, isNot(closeTo(2.0, 1e-6)));
    });

    test('an empty pattern is a solid line', () {
      final ui.Path line = horizontalLine(100);
      expect(identical(dashHudPath(line, <double>[], 0), line), isTrue);
      final _RecordingCanvas canvas = _RecordingCanvas();
      final HudPaintResult result = paintHudCommands(
        canvas: canvas,
        commands: wireStream(<Object?>[
          <Object?>['path', 'ring', 2.0, <Object?>[1, 1, 1, 1], <Object?>[], 0],
        ]),
        path: (String key) => horizontalLine(100),
      );
      expect(result.issues, isEmpty);
      expect(dashSegmentLengths(canvas.paths.single).single, closeTo(100, 1e-6));
    });
  });

  group('defined behaviour for degenerate dashes', () {
    test('a zero-length dash entry records nonPositiveDash and draws solid', () {
      final _RecordingCanvas canvas = _RecordingCanvas();
      final HudPaintResult result = paintHudCommands(
        canvas: canvas,
        commands: wireStream(<Object?>[
          <Object?>['path', 'ring', 3.0, <Object?>[1, 1, 1, 1], <Object?>[6, 0], 4],
        ]),
        path: (String key) => horizontalLine(100),
      );
      expect(result.issues.single.kind, HudPaintIssueKind.nonPositiveDash);
      expect(result.issues.single.op, 'path');
      // solid, not dashes: one contour of the full length
      expect(dashSegmentLengths(canvas.paths.single).single, closeTo(100, 1e-6));
    });

    test('a negative dash entry behaves the same (Qt would clamp it to 0)', () {
      final _RecordingCanvas canvas = _RecordingCanvas();
      final HudPaintResult result = paintHudCommands(
        canvas: canvas,
        commands: wireStream(<Object?>[
          <Object?>['path', 'ring', 3.0, <Object?>[1, 1, 1, 1], <Object?>[-6, 3], 0],
        ]),
        path: (String key) => horizontalLine(100),
      );
      expect(result.issues.single.kind, HudPaintIssueKind.nonPositiveDash);
      expect(dashSegmentLengths(canvas.paths.single).single, closeTo(100, 1e-6));
    });

    test('dashHudPath keeps a defined fallback for degenerate patterns', () {
      final ui.Path line = horizontalLine(20);
      expect(identical(dashHudPath(line, <double>[6, 0], 0), line), isTrue);
      expect(identical(dashHudPath(line, <double>[0, 0], 0), line), isTrue);
      expect(identical(dashHudPath(line, <double>[double.nan], 0), line), isTrue);
    });
  });

  group('layering rules', () {
    test('unknown ops are dropped by the decoder, never by the painter', () {
      final HudCommandDecode decoded = decodeHudCommands(<Object?>[
        <Object?>['warp-drive', 1, 2],
        <Object?>['save'],
        <Object?>['restore'],
      ]);
      expect(decoded.issues.single.kind, HudIssueKind.unknownOperation);
      expect(decoded.commands.length, 2);

      final _RecordingCanvas canvas = _RecordingCanvas();
      final HudPaintResult result = paintHudCommands(
        canvas: canvas,
        commands: decoded.commands,
      );
      // the painter never saw the unknown op, and it did not invent an issue
      expect(result.issues, isEmpty);
      expect(canvas.saveCount, 1);
      expect(canvas.restoreCount, 1);
    });

    test('the painter keeps a supplied state stack instead of a fresh one', () {
      final HudPaintStateStack stack = HudPaintStateStack(opacity: 0.5);
      final _RecordingCanvas canvas = _RecordingCanvas();
      final HudPaintResult result = paintHudCommands(
        canvas: canvas,
        commands: wireStream(<Object?>[
          <Object?>['alpha', 0.5],
        ]),
        state: stack,
      );
      expect(identical(result.state, stack), isTrue);
      expect(result.state.opacity, closeTo(0.25, 1e-12));
    });
  });
}
