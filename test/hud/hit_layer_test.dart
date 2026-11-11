/// hit_layer 的断言：逐条对齐 Qt 源（Qt/qml/Overlay.qml、Qt/src/NativeApplication.cpp、
/// Qt/src/NativeHud.cpp、Qt/src/Engine.cpp）。
///
/// RED 与 GREEN 均**未执行**（本卡禁令：不得运行 flutter test / dart test / dart analyze），
/// 本文件是静态可审读的断言集，不是已跑过的证据。
/// 依赖 T30 的 lib/hud/protocol/hud_hit.dart，跨树集成，本树暂时无法解析该 import，属预期状态。
library;

import 'dart:ui' show Offset, Rect;

import 'package:flutter_test/flutter_test.dart';
import 'package:rhine_music_database/hud/input/hit_layer.dart';
import 'package:rhine_music_database/hud/protocol/hud_hit.dart';

HudHit hitTarget(double x, double y, double width, double height, String action,
        {String? label, bool fixed = false}) =>
    HudHit(
        x: x,
        y: y,
        width: width,
        height: height,
        action: action,
        label: label ?? action,
        fixed: fixed);
void main() {
  const unit = StageGeometry(logicalWidth: 1080, logicalHeight: 1080);
  const half = StageGeometry(logicalWidth: 960, logicalHeight: 540);

  group('StageGeometry (Overlay.qml:22-23)', () {
    test('stageScale is logicalHeight / 1080', () {
      expect(unit.stageScale, 1.0);
      expect(half.stageScale, 0.5);
    });

    test('stageScale falls back to 1 when logicalHeight is not positive', () {
      expect(const StageGeometry(logicalWidth: 960, logicalHeight: 0).stageScale, 1.0);
    });

    test('stageWidth is logicalWidth / stageScale', () {
      expect(unit.stageWidth, 1080.0);
      expect(half.stageWidth, 1920.0);
    });

    test('toStage divides by stageScale, toLogical multiplies', () {
      expect(half.toStage(const Offset(100, 50)), const Offset(200, 100));
      expect(half.toLogical(const Offset(200, 100)), const Offset(100, 50));
    });

    test('rectToLogical scales every edge', () {
      expect(half.rectToLogical(const Rect.fromLTWH(10, 20, 30, 40)),
          const Rect.fromLTWH(5, 10, 15, 20));
    });
  });

  group('StageGeometry.withScale is the only portrait scale (DEDUP-13)', () {
    test('explicit scale wins over the legacy landscape derivation', () {
      final scaled =
          StageGeometry.withScale(stageScale: 1.0, logicalWidth: 1080, logicalHeight: 2400);
      expect(scaled.stageScale, 1.0);
      expect(scaled.stageWidth, 1080.0);
      // 旧横屏构造仍可服务未迁移横向调用方，但它不能用于竖屏。
      const legacy = StageGeometry(logicalWidth: 2160, logicalHeight: 1080);
      expect(legacy.stageScale, 1.0);
      expect(legacy.stageWidth, 2160.0);
    });

    test('legacy landscape constructor rejects portrait geometry', () {
      expect(
          () => StageGeometry(logicalWidth: 1080, logicalHeight: 2400),
          throwsAssertionError);
    });

    test('1440x3200 injects 4/3 and still spans a 1080-wide stage', () {
      final scaled = StageGeometry.withScale(
          stageScale: 1440 / 1080, logicalWidth: 1440, logicalHeight: 3200);
      expect(scaled.stageScale, closeTo(4 / 3, 1e-12));
      expect(scaled.stageWidth, closeTo(1080.0, 1e-9));
    });

    test('non-positive scale or logical size is rejected', () {
      expect(
          () => StageGeometry.withScale(
              stageScale: 0, logicalWidth: 1080, logicalHeight: 2400),
          throwsArgumentError);
      expect(
          () => StageGeometry.withScale(
              stageScale: -1, logicalWidth: 1080, logicalHeight: 2400),
          throwsArgumentError);
      expect(
          () => StageGeometry.withScale(
              stageScale: 1, logicalWidth: 0, logicalHeight: 2400),
          throwsArgumentError);
    });
  });

  group('TouchExpansion (Overlay.qml:38-43)', () {
    test('android pad is 16 stage pixels, everything else has none', () {
      expect(TouchExpansion.androidPad, 16.0);
      expect(TouchExpansion.padFor(android: true), 16.0);
      expect(TouchExpansion.padFor(android: false), 0.0);
    });
  });

  group('HitLayer.containsClosed (Overlay.qml:271 / NativeApplication.cpp:221)', () {
    final rect = const Rect.fromLTWH(10, 20, 30, 40);

    test('the right and bottom edges belong to the rect', () {
      expect(HitLayer.containsClosed(rect, const Offset(40, 60)), isTrue);
      expect(HitLayer.containsClosed(rect, const Offset(40, 20)), isTrue);
      expect(HitLayer.containsClosed(rect, const Offset(10, 60)), isTrue);
    });

    test('Dart Rect.contains would drop those edges, which is why the helper exists', () {
      expect(rect.contains(const Offset(40, 60)), isFalse);
      expect(HitLayer.containsClosed(rect, const Offset(40, 60)), isTrue);
    });

    test('anything past the edges is outside', () {
      expect(HitLayer.containsClosed(rect, const Offset(40.001, 60)), isFalse);
      expect(HitLayer.containsClosed(rect, const Offset(40, 60.001)), isFalse);
      expect(HitLayer.containsClosed(rect, const Offset(9.999, 20)), isFalse);
    });
  });

  group('HitLayer.effectiveRect (Overlay.qml:189-196)', () {
    final base = hitTarget(10, 20, 30, 40, 'music:base');

    test('without padding and without modal the rect is the source rect', () {
      final layer = HitLayer(geometry: unit, android: false);
      expect(layer.offsetY(base), 20.0);
      expect(layer.effectiveRect(base), const Rect.fromLTWH(10, 20, 30, 40));
    });

    test('android pads all four edges by 16', () {
      final layer = HitLayer(geometry: unit, android: true);
      expect(layer.effectiveRect(base), const Rect.fromLTWH(-6, 4, 62, 72));
    });

    test('the modal offset is applied only while a modal is open', () {
      final closed = HitLayer(geometry: unit, android: false, modalOffset: 56);
      expect(closed.effectiveRect(base), const Rect.fromLTWH(10, 20, 30, 40));

      final open = HitLayer(geometry: unit, android: false, modal: 'search', modalOffset: 56);
      expect(open.offsetY(base), 76.0);
      expect(open.effectiveRect(base), const Rect.fromLTWH(10, 76, 30, 40));
    });

    test('padding and modal offset compose: pad first, then the offset', () {
      final layer = HitLayer(geometry: unit, android: true, modal: 'search', modalOffset: 56);
      expect(layer.effectiveRect(base), const Rect.fromLTWH(-6, 60, 62, 72));
      expect(layer.scanRect(base), const Rect.fromLTWH(-6, 4, 62, 72));
    });

    test('fixed targets never take the modal offset, with or without padding', () {
      final layer = HitLayer(geometry: unit, android: false, modal: 'player', modalOffset: 56);
      final fixed = hitTarget(10, 20, 30, 40, 'music:like-current', fixed: true);
      expect(layer.offsetY(fixed), 20.0);
      expect(layer.effectiveRect(fixed), const Rect.fromLTWH(10, 20, 30, 40));

      final padded = HitLayer(geometry: unit, android: true, modal: 'player', modalOffset: 56);
      expect(padded.effectiveRect(fixed), const Rect.fromLTWH(-6, 4, 62, 72));
    });

    test('the source hit is never rewritten by consumption', () {
      final layer = HitLayer(geometry: unit, android: true, modal: 'search', modalOffset: 56);
      layer.effectiveRect(base);
      layer.scanRect(base);
      expect(base.x, 10.0);
      expect(base.y, 20.0);
      expect(base.width, 30.0);
      expect(base.height, 40.0);
      expect(base.fixed, isFalse);
    });
  });

  group('HitLayer.hitAt (Overlay.qml:185-220 topmost delegate wins)', () {
    final layer = HitLayer(geometry: unit, android: false);
    final lower = hitTarget(0, 0, 100, 100, 'music:lower');
    final upper = hitTarget(0, 0, 100, 100, 'music:upper');

    test('the last containing hit wins, not the first', () {
      expect(layer.hitAt(<HudHit>[lower, upper], const Offset(50, 50)), upper);
      expect(layer.hitAt(<HudHit>[upper, lower], const Offset(50, 50)), lower);
    });

    test('nothing containing the point yields null', () {
      expect(layer.hitAt(<HudHit>[lower, upper], const Offset(500, 500)), isNull);
      expect(layer.hitAt(const <HudHit>[], const Offset(50, 50)), isNull);
    });

    test('a point on the right or bottom edge still hits', () {
      final rect = hitTarget(10, 20, 30, 40, 'music:edge');
      expect(layer.hitAt(<HudHit>[rect], const Offset(40, 60)), rect);
      expect(layer.hitAt(<HudHit>[rect], const Offset(40.5, 60)), isNull);
    });

    test('the point is logical and is compared in stage space', () {
      final single = hitTarget(0, 0, 100, 100, 'music:x');
      expect(half.hitAt(<HudHit>[single], const Offset(40, 40)), single);
      expect(half.hitAt(<HudHit>[single], const Offset(240, 240)), isNull);
    });

    test('android padding widens the touch target', () {
      final small = hitTarget(0, 0, 10, 10, 'music:x');
      final ios = HitLayer(geometry: unit, android: false);
      final android = HitLayer(geometry: unit, android: true);
      expect(ios.hitAt(<HudHit>[small], const Offset(14, 14)), isNull);
      expect(android.hitAt(<HudHit>[small], const Offset(14, 14)), small);
    });
  });

  group('HitLayer.firstResultHit (Overlay.qml:262-278 forward scan)', () {
    final layer = HitLayer(geometry: unit, android: false);
    final first = hitTarget(0, 0, 200, 60, 'music:result:1');
    final second = hitTarget(0, 0, 200, 60, 'music:expand:2');
    final other = hitTarget(0, 0, 200, 60, 'music:play:3');

    test('the first result hit in wire order wins', () {
      expect(layer.firstResultHit(<HudHit>[second, first], const Offset(50, 30)), second);
      expect(layer.firstResultHit(<HudHit>[first, second], const Offset(50, 30)), first);
    });

    test('actions without a result prefix are skipped', () {
      expect(layer.firstResultHit(<HudHit>[other, first], const Offset(50, 30)), first);
    });

    test('no matching result hit yields null', () {
      expect(layer.firstResultHit(<HudHit>[other, first], const Offset(900, 900)), isNull);
    });

    test('only music:result: and music:expand: count as scrollable rows', () {
      expect(HitLayer.resultPrefixes, <String>['music:result:', 'music:expand:']);
      expect(HitLayer.hasResultPrefix('music:result:7'), isTrue);
      expect(HitLayer.hasResultPrefix('music:expand:x'), isTrue);
      expect(HitLayer.hasResultPrefix('music:result'), isFalse);
      expect(HitLayer.hasResultPrefix('music:play:1'), isFalse);
    });

    test('the scan point carries no modalOffset, unlike hitAt', () {
      final modal = HitLayer(geometry: unit, android: true, modal: 'search', modalOffset: 56);
      final row = hitTarget(10, 20, 30, 40, 'music:result:9');
      // scanRect 覆盖 [4,72]，effectiveRect 覆盖 [60,132]。
      expect(modal.scanRect(row), const Rect.fromLTWH(-6, 4, 62, 72));
      expect(modal.effectiveRect(row), const Rect.fromLTWH(-6, 60, 62, 72));
      expect(modal.firstResultHit(<HudHit>[row], const Offset(5, 20)), row);
      expect(modal.firstResultHit(<HudHit>[row], const Offset(5, 100)), isNull);
      expect(HitLayer.containsClosed(modal.effectiveRect(row), const Offset(5, 100)), isTrue);
    });
  });

  group('HitLayer.isShielded (NativeApplication.cpp:216-222)', () {
    final bounds = Rect.fromLTWH(0, 984, 1080, 96);
    final layer = HitLayer(geometry: unit, android: false, playerBounds: bounds);

    test('a stage point inside playerBounds is shielded', () {
      expect(layer.isShielded(const Offset(50, 1000)), isTrue);
      expect(layer.isShielded(const Offset(50, 900)), isFalse);
    });

    test('the far corner belongs to the region', () {
      expect(layer.isShielded(const Offset(1080, 1080)), isTrue);
      expect(layer.isShielded(const Offset(1081, 1080)), isFalse);
    });

    test('no playerBounds shields nothing', () {
      expect(HitLayer(geometry: unit, android: false).isShielded(const Offset(50, 1000)), isFalse);
    });

    test('the logical entry converts through stageScale before comparing', () {
      final scaled = HitLayer(geometry: half, android: false, playerBounds: bounds);
      expect(scaled.isShieldedLogical(const Offset(25, 500)), isTrue);
      expect(scaled.isShieldedLogical(const Offset(25, 400)), isFalse);
    });
  });

  group('HitLayer.playerControlRect (Overlay.qml:485-508)', () {
    final region = const Rect.fromLTWH(10, 400, 200, 30);

    test('x and width stay untouched, only y and height take the padding', () {
      final android = HitLayer(geometry: unit, android: true);
      expect(android.playerControlRect(region), const Rect.fromLTWH(10, 384, 200, 62));

      final ios = HitLayer(geometry: unit, android: false);
      expect(ios.playerControlRect(region), region);
    });
  });

  group('HitLayer.playerFractionAction (Engine.cpp:1016-1021)', () {
    test('a non-positive width is rejected', () {
      expect(HitLayer.playerFractionAction(control: 'seek', x: 50, width: 0), isNull);
      expect(HitLayer.playerFractionAction(control: 'seek', x: 50, width: -10), isNull);
    });

    test('only seek and volume are accepted controls', () {
      expect(HitLayer.playerFractionAction(control: 'seek', x: 50, width: 200),
          'player:seek-fraction:0.25');
      expect(HitLayer.playerFractionAction(control: 'volume', x: 100, width: 200),
          'player:volume-fraction:0.5');
      expect(HitLayer.playerFractionAction(control: 'foo', x: 50, width: 200), isNull);
    });

    test('the fraction is clamped to [0,1] and formatted with g16', () {
      expect(HitLayer.playerFractionAction(control: 'seek', x: -50, width: 200),
          'player:seek-fraction:0');
      expect(HitLayer.playerFractionAction(control: 'seek', x: 200, width: 200),
          'player:seek-fraction:1');
      expect(HitLayer.playerFractionAction(control: 'seek', x: 400, width: 200),
          'player:seek-fraction:1');
    });
  });

  group('HitLayer.formatG16 (QString::number(v, g, 16))', () {
    test('zero and whole numbers print without a decimal point', () {
      expect(HitLayer.formatG16(0.0), '0');
      expect(HitLayer.formatG16(1.0), '1');
    });

    test('exact fractions keep their value and drop trailing zeros', () {
      expect(HitLayer.formatG16(0.5), '0.5');
      expect(HitLayer.formatG16(0.25), '0.25');
      expect(HitLayer.formatG16(0.125), '0.125');
    });

    test('a repeating fraction keeps 16 significant digits', () {
      expect(HitLayer.formatG16(1 / 3), '0.3333333333333333');
    });

    test('the decimal exponent switches to scientific below -4 and at 16', () {
      expect(HitLayer.formatG16(0.0001), '0.0001');
      expect(HitLayer.formatG16(0.00001), '1e-05');
      expect(HitLayer.formatG16(1e16), '1e+16');
    });

    test('non-finite inputs follow the C/Qt spelling', () {
      expect(HitLayer.formatG16(double.nan), 'nan');
      expect(HitLayer.formatG16(double.infinity), 'inf');
      expect(HitLayer.formatG16(double.negativeInfinity), '-inf');
    });
  });

  group('HitLayer.firesOnPress (Overlay.qml:202-212)', () {
    test('the judgement is !ios, so only iOS waits for the release', () {
      expect(HitLayer.firesOnPress(ios: true), isFalse);
      expect(HitLayer.firesOnPress(ios: false), isTrue);
    });
  });
}
