// T30-C18 render atom tests, WRITTEN BUT NOT EXECUTED（本卡禁止 flutter/dart test/analyze）。
//
// 覆盖 lib/hud/render/clip_alpha.dart：opacity 乘算（Qt/src/Glyphs.cpp:658-659）
// 与 clip 相交（Qt/src/Glyphs.cpp:676-678）。判定语义的唯一权威是 Qt 源：
//   third_party/qt/qtbase/src/corelib/tools/qrect.cpp:2226-2276  QRectF::operator&
//   third_party/qt/qtbase/src/corelib/tools/qrect.cpp:1553-1565  QRectF::normalized
//   third_party/qt/qtbase/src/corelib/tools/qrect.h:687-696      isNull/isEmpty/isValid
//   third_party/qt/qtbase/src/gui/painting/qpainter.cpp:2073     setOpacity 的 [0,1] 夹取
//   third_party/qt/qtbase/src/gui/painting/qpainter.cpp:1603-1606 不平衡 restore 只告警
//   third_party/qt/qtbase/src/gui/painting/qpainter_p.h:136       opacity 默认 1
//
// 本卡禁止任何 flutter/dart test、analyze、build、codegen，所以 RED/GREEN 都是
// 「未执行」：每条 expect 都是读 Qt 源与实现推出来的，不是跑出来的。
// 这里也不含任何像素/SSIM/ΔE 断言——只有矩形与标量算术。

import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:rhine_music_database/hud/render/clip_alpha.dart';

/// QRectF(x, y, w, h) — same argument order as the Qt wire (n(1)..n(4)).
ui.Rect qrect(double x, double y, double w, double h) =>
    ui.Rect.fromLTWH(x, y, w, h);

void main() {
  // ── alpha：Glyphs.cpp:658-659  c.setOpacity(c.opacity() * n(1)) ──
  group('composeHudOpacity', () {
    test('is the raw product of accumulated opacity and the factor', () {
      expect(composeHudOpacity(1.0, 1.0), 1.0);
      expect(composeHudOpacity(1.0, 0.5), 0.5);
      expect(composeHudOpacity(0.5, 0.5), 0.25);
      expect(composeHudOpacity(0.25, 0.0), 0.0);
    });

    test('accumulates multiplicatively over nested alpha ops', () {
      // 1.0 * 0.5 * 0.5 == 0.25: nested alpha multiplies, it never replaces.
      var opacity = 1.0;
      opacity = composeHudOpacity(opacity, 0.5);
      opacity = composeHudOpacity(opacity, 0.5);
      expect(opacity, 0.25);
    });

    test('does not clamp: the clamp belongs to QPainter::setOpacity', () {
      // qpainter.cpp:2073 clamps with qMin(1, qMax(0, opacity)). Keeping the
      // primitive a pure product leaves that clamp — and the issue log for
      // out-of-range wire values — to the painter's alpha op. Factors inside
      // [0, 1] are unaffected either way.
      expect(composeHudOpacity(1.0, 1.5), 1.5);
      expect(composeHudOpacity(0.5, 2.0), 1.0);
    });
  });

  // ── clip：Glyphs.cpp:676-678 + QRectF::operator& (qrect.cpp:2226-2276) ──
  group('intersectHudClip', () {
    test('nested rects return the inner rect', () {
      // qrect.cpp:2270-2275: x = qMax(l1,l2), w = qMin(r1,r2) - x.
      expect(
        intersectHudClip(qrect(0, 0, 100, 100), qrect(10, 10, 50, 50)),
        qrect(10, 10, 50, 50),
      );
      expect(
        intersectHudClip(qrect(10, 10, 50, 50), qrect(0, 0, 100, 100)),
        qrect(10, 10, 50, 50),
      );
    });

    test('partially overlapping rects clip to the overlap', () {
      expect(
        intersectHudClip(qrect(0, 0, 100, 100), qrect(50, 25, 100, 100)),
        qrect(50, 25, 50, 75),
      );
    });

    test('identical rects are idempotent', () {
      expect(
        intersectHudClip(qrect(4, 8, 16, 32), qrect(4, 8, 16, 32)),
        qrect(4, 8, 16, 32),
      );
    });

    test('disjoint rects return the null rect at the origin', () {
      // qrect.cpp:2246-2247 return QRectF(), i.e. (0, 0, 0, 0).
      expect(
        intersectHudClip(qrect(0, 0, 10, 10), qrect(20, 20, 10, 10)),
        ui.Rect.zero,
      );
      expect(
        intersectHudClip(qrect(-40, -40, 10, 10), qrect(0, 0, 10, 10)),
        ui.Rect.zero,
      );
    });

    test('edge-adjacent rects are empty, not zero-thickness strips', () {
      // Qt compares strictly (l1 >= r2, t1 >= b2): sharing an edge has zero
      // area, so the result is QRectF() at the origin, never a strip parked on
      // the shared edge (qrect.cpp:2246-2247, 2267-2268).
      expect(
        intersectHudClip(qrect(0, 0, 10, 10), qrect(10, 0, 10, 10)),
        ui.Rect.zero,
      );
      expect(
        intersectHudClip(qrect(0, 0, 10, 10), qrect(0, 10, 10, 10)),
        ui.Rect.zero,
      );
      expect(
        intersectHudClip(qrect(0, 0, 10, 10), qrect(-10, 0, 10, 10)),
        ui.Rect.zero,
      );
    });

    test('a zero-width or zero-height operand yields the null rect', () {
      // qrect.cpp:2234-2244 (width) and 2255-2265 (height) short-circuit.
      expect(
        intersectHudClip(qrect(0, 0, 0, 10), qrect(-5, -5, 20, 20)),
        ui.Rect.zero,
      );
      expect(
        intersectHudClip(qrect(3, 3, 10, 0), qrect(0, 0, 100, 100)),
        ui.Rect.zero,
      );
      expect(
        intersectHudClip(qrect(0, 0, 0, 0), qrect(0, 0, 100, 100)),
        ui.Rect.zero,
      );
    });

    test('normalizes a negative width before intersecting', () {
      // qrect.cpp:1556-1559: w < 0 -> x += w; w = -w.
      expect(
        intersectHudClip(ui.Rect.fromLTWH(100, 0, -40, 10), qrect(0, 0, 200, 200)),
        qrect(60, 0, 40, 10),
      );
    });

    test('normalizes a negative height before intersecting', () {
      // qrect.cpp:1560-1563: h < 0 -> y += h; h = -h.
      expect(
        intersectHudClip(qrect(0, 0, 100, 100), ui.Rect.fromLTWH(0, 100, 10, -40)),
        qrect(0, 60, 10, 40),
      );
    });

    test('normalizes both axes of a doubly negative rect', () {
      expect(
        intersectHudClip(ui.Rect.fromLTWH(50, 50, -10, -20), qrect(0, 0, 100, 100)),
        qrect(40, 30, 10, 20),
      );
    });

    test('never returns a negative extent', () {
      final pairs = <List<ui.Rect>>[
        <ui.Rect>[qrect(0, 0, 10, 10), qrect(20, 20, 10, 10)],
        <ui.Rect>[qrect(0, 0, 10, 10), qrect(10, 0, 10, 10)],
        <ui.Rect>[ui.Rect.fromLTWH(5, 5, -3, -3), qrect(0, 0, 100, 100)],
        <ui.Rect>[qrect(0, 0, 1920, 1080), qrect(1600, 900, 320, 180)],
      ];
      for (final pair in pairs) {
        final result = intersectHudClip(pair[0], pair[1]);
        expect(result.width >= 0, isTrue, reason: 'width of ' + result.toString());
        expect(result.height >= 0, isTrue, reason: 'height of ' + result.toString());
      }
    });
  });

  // ── 状态快照值语义 ──
  group('HudPainterState', () {
    test('value equality covers opacity, clip and depth', () {
      const a = HudPainterState(opacity: 0.5, clip: null, depth: 2);
      const b = HudPainterState(opacity: 0.5, clip: null, depth: 2);
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(
        a == const HudPainterState(opacity: 0.5, clip: null, depth: 3),
        isFalse,
      );
      expect(
        a == const HudPainterState(opacity: 0.25, clip: null, depth: 2),
        isFalse,
      );
      expect(
        a == HudPainterState(opacity: 0.5, clip: qrect(0, 0, 1, 1), depth: 2),
        isFalse,
      );
      expect(
        a == HudPainterState(opacity: 0.5, clip: ui.Rect.zero, depth: 2),
        isFalse,
      );
    });

    test('toString exposes all three fields', () {
      const root = HudPainterState(opacity: 1.0, clip: null, depth: 0);
      expect(root.toString(), contains('opacity: 1.0'));
      expect(root.toString(), contains('clip: null'));
      expect(root.toString(), contains('depth: 0'));

      final clipped = HudPainterState(
        opacity: 0.5,
        clip: qrect(0, 0, 10, 20),
        depth: 1,
      );
      expect(
        clipped.toString(),
        contains('clip: ' + qrect(0, 0, 10, 20).toString()),
      );
    });
  });

  group('HudPaintStateStack initial state', () {
    test('starts with opacity 1.0, depth 0, no clip', () {
      final stack = HudPaintStateStack();
      expect(stack.opacity, 1.0); // qpainter_p.h:136
      expect(stack.depth, 0);
      expect(stack.hasClip, isFalse);
      expect(stack.clip, isNull);
      expect(stack.isBalanced, isTrue);
      expect(stack.states, isEmpty);
    });

    test('constructor overrides are visible but push no frame', () {
      final stack = HudPaintStateStack(opacity: 0.5, clip: qrect(10, 20, 30, 40));
      expect(stack.opacity, 0.5);
      expect(stack.clip, qrect(10, 20, 30, 40));
      expect(stack.hasClip, isTrue);
      expect(stack.depth, 0);
      expect(stack.states, isEmpty);
    });

    test('constructor normalizes a negative-size clip', () {
      final stack = HudPaintStateStack(clip: ui.Rect.fromLTWH(100, 50, -40, -20));
      expect(stack.clip, qrect(60, 30, 40, 20));
    });
  });

  // ── save/restore：Glyphs.cpp:644-657 + qpainter.cpp:1562-1606 ──
  group('HudPaintStateStack save/restore', () {
    test('save raises depth and records the pre-save frame', () {
      final stack = HudPaintStateStack();
      stack.save();
      expect(stack.depth, 1);
      expect(stack.isBalanced, isFalse);
      expect(stack.states, hasLength(1));
      expect(
        stack.states.single,
        const HudPainterState(opacity: 1.0, clip: null, depth: 0),
      );
    });

    test('nested saves record increasing depths and captured values', () {
      final stack = HudPaintStateStack();
      stack.save();
      stack.applyAlpha(0.5);
      stack.save();
      stack.applyClip(qrect(0, 0, 10, 10));
      stack.save();
      expect(stack.depth, 3);
      expect(stack.states.map((s) => s.depth), <int>[0, 1, 2]);
      expect(stack.states.map((s) => s.opacity), <double>[1.0, 0.5, 0.5]);
      expect(stack.states.last.clip, qrect(0, 0, 10, 10));
    });

    test('restore returns true, pops one frame and rewinds state', () {
      final stack = HudPaintStateStack();
      stack.save();
      stack.applyAlpha(0.5);
      stack.applyClip(qrect(1, 2, 3, 4));
      expect(stack.restore(), isTrue);
      expect(stack.depth, 0);
      expect(stack.opacity, 1.0);
      expect(stack.clip, isNull);
      expect(stack.hasClip, isFalse);
      expect(stack.isBalanced, isTrue);
      expect(stack.states, isEmpty);
    });

    test('restore rewinds depth one frame at a time', () {
      final stack = HudPaintStateStack();
      stack.save();
      stack.save();
      stack.save();
      expect(stack.depth, 3);
      expect(stack.restore(), isTrue);
      expect(stack.depth, 2);
      expect(stack.restore(), isTrue);
      expect(stack.depth, 1);
      expect(stack.restore(), isTrue);
      expect(stack.depth, 0);
      expect(stack.restore(), isFalse);
      expect(stack.depth, 0);
    });

    test('unbalanced restore returns false and changes nothing', () {
      final stack = HudPaintStateStack(opacity: 0.25, clip: qrect(5, 6, 7, 8));
      expect(stack.restore(), isFalse);
      expect(stack.opacity, 0.25);
      expect(stack.clip, qrect(5, 6, 7, 8));
      expect(stack.depth, 0);
      expect(stack.states, isEmpty);
      // qpainter.cpp:1603-1606: warn and stay put — repeated calls are no-ops.
      expect(stack.restore(), isFalse);
      expect(stack.opacity, 0.25);
      expect(stack.clip, qrect(5, 6, 7, 8));
      expect(stack.depth, 0);
    });

    test('restore after the stack is drained stays unbalanced', () {
      final stack = HudPaintStateStack();
      stack.save();
      expect(stack.restore(), isTrue);
      expect(stack.restore(), isFalse);
      expect(stack.opacity, 1.0);
      expect(stack.clip, isNull);
      expect(stack.depth, 0);
    });

    test('a snapshot is a copy: later ops cannot mutate it', () {
      final stack = HudPaintStateStack();
      stack.save();
      stack.applyAlpha(0.5);
      stack.applyClip(qrect(7, 8, 9, 10));
      expect(stack.states.single.opacity, 1.0);
      expect(stack.states.single.clip, isNull);
      expect(stack.states.single.depth, 0);
    });

    test('an inner empty clip does not leak past restore', () {
      final stack = HudPaintStateStack();
      stack.applyClip(qrect(0, 0, 1920, 1080));
      stack.save();
      stack.applyClip(qrect(2000, 2000, 10, 10)); // disjoint -> empty
      expect(stack.clip, ui.Rect.zero);
      expect(stack.restore(), isTrue);
      expect(stack.clip, qrect(0, 0, 1920, 1080));
    });
  });

  // ── alpha 在栈上的行为 ──
  group('HudPaintStateStack applyAlpha', () {
    test('multiplies instead of replacing (1.0 * 0.5 * 0.5 == 0.25)', () {
      final stack = HudPaintStateStack();
      stack.applyAlpha(0.5);
      expect(stack.opacity, 0.5);
      stack.applyAlpha(0.5);
      expect(stack.opacity, 0.25);
      expect(stack.depth, 0);
      expect(stack.clip, isNull);
    });

    test('accumulates inside nested frames and rewinds on restore', () {
      final stack = HudPaintStateStack();
      stack.save();
      stack.applyAlpha(0.5); // 0.5
      stack.save();
      stack.applyAlpha(0.5); // 0.25
      expect(stack.opacity, 0.25);
      expect(stack.restore(), isTrue);
      expect(stack.opacity, 0.5);
      expect(stack.restore(), isTrue);
      expect(stack.opacity, 1.0);
    });

    test('alpha never touches depth or clip', () {
      final stack = HudPaintStateStack(clip: qrect(0, 0, 10, 10));
      stack.applyAlpha(0.5);
      expect(stack.depth, 0);
      expect(stack.clip, qrect(0, 0, 10, 10));
      expect(stack.hasClip, isTrue);
    });
  });

  // ── clip 在栈上的行为 ──
  group('HudPaintStateStack applyClip', () {
    test('first clip sets the rect and returns it', () {
      final stack = HudPaintStateStack();
      final applied = stack.applyClip(qrect(10, 20, 100, 200));
      expect(applied, qrect(10, 20, 100, 200));
      expect(stack.clip, applied);
      expect(stack.hasClip, isTrue);
      expect(stack.opacity, 1.0);
      expect(stack.depth, 0);
    });

    test('second clip intersects with the first (Qt IntersectClip)', () {
      final stack = HudPaintStateStack();
      stack.applyClip(qrect(0, 0, 100, 100));
      final applied = stack.applyClip(qrect(50, 25, 100, 100));
      expect(applied, qrect(50, 25, 50, 75));
      expect(stack.clip, applied);
    });

    test('return value always equals the clip getter', () {
      final stack = HudPaintStateStack();
      expect(stack.applyClip(qrect(0, 0, 1920, 1080)), stack.clip);
      expect(stack.applyClip(qrect(0, 900, 1920, 180)), stack.clip);
      expect(stack.applyClip(qrect(5000, 5000, 10, 10)), stack.clip);
    });

    test('disjoint clip becomes empty but stays set', () {
      final stack = HudPaintStateStack();
      stack.applyClip(qrect(0, 0, 10, 10));
      expect(stack.applyClip(qrect(20, 20, 10, 10)), ui.Rect.zero);
      expect(stack.clip, ui.Rect.zero);
      // Qt stays clipped once setClipRect has run: empty is not "unclipped".
      expect(stack.hasClip, isTrue);
      // Intersecting an empty clip with anything stays empty.
      expect(stack.applyClip(qrect(-100, -100, 400, 400)), ui.Rect.zero);
      expect(stack.clip, ui.Rect.zero);
    });

    test('repeated identical clips are idempotent', () {
      final stack = HudPaintStateStack();
      stack.applyClip(qrect(3, 4, 5, 6));
      expect(stack.applyClip(qrect(3, 4, 5, 6)), qrect(3, 4, 5, 6));
      expect(stack.clip, qrect(3, 4, 5, 6));
    });

    test('first clip normalizes a negative-size rect', () {
      final stack = HudPaintStateStack();
      expect(
        stack.applyClip(ui.Rect.fromLTWH(100, 0, -40, 10)),
        qrect(60, 0, 40, 10),
      );
    });

    test('clip is rewound by restore', () {
      final stack = HudPaintStateStack();
      stack.applyClip(qrect(0, 0, 100, 100));
      stack.save();
      stack.applyClip(qrect(10, 10, 20, 20));
      expect(stack.clip, qrect(10, 10, 20, 20));
      expect(stack.restore(), isTrue);
      expect(stack.clip, qrect(0, 0, 100, 100));
    });
  });

  // ── states 只读快照 ──
  group('HudPaintStateStack states snapshot', () {
    test('a snapshot is unaffected by later saves', () {
      final stack = HudPaintStateStack();
      stack.save();
      final snapshot = stack.states;
      expect(snapshot, hasLength(1));
      stack.save();
      expect(snapshot, hasLength(1));
      expect(stack.states, hasLength(2));
    });

    test('each call returns an independent unmodifiable list', () {
      final stack = HudPaintStateStack();
      stack.save();
      final first = stack.states;
      final second = stack.states;
      expect(identical(first, second), isFalse);
      expect(
        () => first.add(
          const HudPainterState(opacity: 1.0, clip: null, depth: 0),
        ),
        throwsUnsupportedError,
      );
    });

    test('oldest frame first, newest last', () {
      final stack = HudPaintStateStack();
      stack.save();
      stack.applyAlpha(0.5);
      stack.save();
      final states = stack.states;
      expect(states.first.depth, 0);
      expect(states.last.depth, 1);
      expect(states.first.opacity, 1.0);
      expect(states.last.opacity, 0.5);
    });
  });

  // ── 舞台尺度上的纯矩形链（不含任何像素/截图断言） ──
  group('1920x1080 stage clip chain (pure rect math, no pixels)', () {
    // Overlay.qml:22-23 stageScale = height > 0 ? height / 1080 : 1 and
    // stageWidth = width / stageScale; the controls Item is
    // width: stageWidth, height: 1080, scale: stageScale, origin TopLeft
    // (Qt/qml/Overlay.qml:179-184). At 1920x1080 the logical stage is exactly
    // 1920x1080. These numbers are rect arithmetic from that geometry, not a
    // measured screenshot.
    test('footer band then right-aligned control keeps the intersection', () {
      final stack = HudPaintStateStack();
      expect(stack.applyClip(qrect(0, 0, 1920, 1080)), qrect(0, 0, 1920, 1080));
      expect(stack.applyClip(qrect(0, 900, 1920, 180)), qrect(0, 900, 1920, 180));
      stack.save();
      expect(
        stack.applyClip(qrect(1600, 900, 320, 180)),
        qrect(1600, 900, 320, 180),
      );
      expect(stack.restore(), isTrue);
      expect(stack.clip, qrect(0, 900, 1920, 180));
      expect(stack.opacity, 1.0);
      expect(stack.depth, 0);
      expect(stack.isBalanced, isTrue);
    });

    test('a clip outside the stage collapses and never reopens', () {
      final stack = HudPaintStateStack();
      stack.applyClip(qrect(0, 0, 1920, 1080));
      stack.save();
      // Shares only the right edge with the stage -> zero area -> empty.
      stack.applyClip(qrect(1920, 0, 100, 100));
      expect(stack.clip, ui.Rect.zero);
      expect(stack.applyClip(qrect(0, 0, 1920, 1080)), ui.Rect.zero);
      expect(stack.restore(), isTrue);
      expect(stack.clip, qrect(0, 0, 1920, 1080));
    });
  });
}
