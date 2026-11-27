/// Tests for the scene frame and the viewer state machine.
///
/// Source of truth (baseline 708677579626f8eaeeef77e8588125ecadab4858):
///  * `Qt/src/NativeSceneFrame.cpp` (214 lines) — the literal frame map
///    (:87-119), the actor entries (:126-159), the model matrix (:189) and the
///    pixel projection (:192-193).
///  * `Qt/src/NativeViewer.cpp` (355 lines) / `.h` (68 lines) — open (:39-64),
///    reduced (:65-76), reset (:77-91), interrupt (:92-98), action (:108-130),
///    key (:131-166), update (:208-274) and the `viewerState` block (:276-355).
///  * `Qt/src/NativeHud.cpp:242-251` and `:280-288` — the 500 ms wall-clock
///    detail fade that takes `max` with the pseudo-clock `frame[detail]` value.
///  * `Qt/src/SceneAppearance.cpp:20-27` (sRGB → linear, three components) and
///    `:28-38` (blend over indices 0..2 only).
///  * `Qt/src/SceneMotion.cpp:113-119` — the critically damped spring the local
///    helper `_damped` reproduces so the clock's step can be asserted.
///  * `Qt/src/Engine.cpp:1353` — the HUD stage rule used by `SceneSize.stage`.
///
/// STATUS: written, deliberately NOT executed. This atom may not run
/// `flutter test`, `flutter analyze`, or any project script, so the file is a
/// static specification of the port: every expectation below is derived from
/// the cited Qt lines rather than from an observed run.
///
/// House rule for this file: `package:flutter_test` is imported because the
/// package has no `package:test` entry and a bare `package:test` import fails at
/// parse time in this repository; `lib/` stays pure Dart and imports no Flutter
/// at all, which is the property these tests are allowed to rely on.
library;

import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:rhine_music_database/scene/scene_frame.dart';
import 'package:rhine_music_database/scene/scene_math.dart';
import 'package:rhine_music_database/scene/viewer_state.dart';

// ---------------------------------------------------------------------------
// Local helpers.
// ---------------------------------------------------------------------------

/// Qt's sRGB → linear curve, written out independently of `LinearRgb` so the
/// test does not merely restate the implementation
/// (`SceneAppearance.cpp:22-23`).
double _srgbToLinear(int channel) {
  final double component = channel / 255.0;
  if (component < 0.04045) {
    return component * 0.0773993808;
  }
  return math.pow(component * 0.9478672986 + 0.0521327014, 2.4).toDouble();
}

/// The spring recurrence of `SceneMotion.cpp:113-119`, used to predict the
/// step the viewer hands to its springs.
List<double> _damped(
  double value,
  double velocity,
  double target,
  double rate,
  double seconds,
) {
  final double delta = value - target;
  final double impulse = velocity + rate * delta;
  final double decay = math.exp(-rate * seconds);
  return <double>[
    target + (delta + impulse * seconds) * decay,
    (velocity - rate * impulse * seconds) * decay,
  ];
}

/// A minimal frame map with the four keys `SceneFrame.fromQtFrame` requires.
Map<String, Object?> _minimalQtFrame() => <String, Object?>{
      'projection': Mat4().toJson(),
      'view': Mat4().toJson(),
      'background': sceneBackground(0).toJson(),
      'fogColor': sceneFogColor(0).toJson(),
    };

void main() {
  // -------------------------------------------------------------------------
  // Stage geometry.
  // -------------------------------------------------------------------------
  group('SceneSize.stage — Qt/src/Engine.cpp:1353', () {
    test('a 16:9 viewport is its own stage', () {
      const SceneSize size = SceneSize(1920, 1080);
      expect(size.stage, const SceneSize(1920, 1080));
      expect(size.stage.height, kStageHeight);
    });

    test('a wider viewport widens the stage and keeps height at 1080', () {
      const SceneSize size = SceneSize(2538, 1080);
      expect(size.stage.width, closeTo(2538, 1e-12));
      expect(size.stage.height, 1080);
    });

    test('a narrower viewport narrows the stage', () {
      const SceneSize size = SceneSize(1080, 1920);
      // 1080 / (1920 / 1080) = 607.5
      expect(size.stage.width, closeTo(607.5, 1e-12));
      expect(size.stage.height, 1080);
    });

    test('a degenerate viewport falls back to 1920x1080', () {
      const SceneSize size = SceneSize(800, 0);
      expect(size.stage, SceneSize.stageFallback);
      expect(size.stage, const SceneSize(1920, 1080));
      expect(size.isEmpty, isTrue);
    });

    test('aspect has no zero guard, exactly like the C++ call sites', () {
      const SceneSize size = SceneSize(100, 0);
      expect(size.aspect.isInfinite, isTrue);
      expect(const SceneSize(1920, 1080).aspect, closeTo(16 / 9, 1e-12));
    });
  });

  // -------------------------------------------------------------------------
  // Linear colour.
  // -------------------------------------------------------------------------
  group('LinearRgb — Qt/src/SceneAppearance.cpp:20-27', () {
    test('white lands on 1 and black on exactly 0', () {
      final LinearRgb white = LinearRgb.fromHex('#ffffff');
      // The transfer function evaluates pow(0.9478672986 + 0.0521327014, 2.4).
      // Both literals are rounded to doubles before the addition, so their sum
      // can miss 1.0 by a few ulps and pow() then returns 1 + n * 2^-52. The
      // endpoint is therefore asserted to 1e-12, not bit-exactly; Qt's double
      // arithmetic has the identical rounding.
      expect(white.r, closeTo(1.0, 1e-12));
      expect(white.g, closeTo(1.0, 1e-12));
      expect(white.b, closeTo(1.0, 1e-12));
      final LinearRgb black = LinearRgb.fromHex('#000000');
      expect(black.r, 0.0);
      expect(black.g, 0.0);
      expect(black.b, 0.0);
    });

    test('the palette literals follow the Qt transfer function', () {
      for (final String hex in <String>['#eae5e1', '#11181b', '#263136']) {
        final LinearRgb colour = LinearRgb.fromHex(hex);
        final int packed = int.parse(hex.substring(1), radix: 16);
        expect(colour.r, closeTo(_srgbToLinear((packed >> 16) & 0xff), 1e-12),
            reason: 'red of $hex');
        expect(colour.g, closeTo(_srgbToLinear((packed >> 8) & 0xff), 1e-12),
            reason: 'green of $hex');
        expect(colour.b, closeTo(_srgbToLinear(packed & 0xff), 1e-12),
            reason: 'blue of $hex');
      }
    });

    test('linear light is darker than sRGB for a mid grey', () {
      final LinearRgb grey = LinearRgb.fromHex('#808080');
      expect(grey.r, lessThan(128 / 255));
      expect(grey.r, greaterThan(0));
    });

    test('no alpha reaches the wire', () {
      final LinearRgb colour = LinearRgb.fromHex('#eae5e1');
      final List<double> json = colour.toJson();
      expect(json.length, 3, reason: 'SceneAppearance::color returns 3 components');
      expect(LinearRgb.fromJson(json), colour);
    });

    test('a fourth component is rejected instead of dropped', () {
      expect(
        () => LinearRgb.fromJson(<Object?>[1.0, 1.0, 1.0, 1.0]),
        throwsA(isA<SceneFrameFormatException>()),
      );
      expect(
        () => LinearRgb.fromJson(<Object?>[1.0, 1.0]),
        throwsA(isA<SceneFrameFormatException>()),
      );
      expect(
        () => LinearRgb.fromJson('not a list'),
        throwsA(isA<SceneFrameFormatException>()),
      );
    });

    test('an #aarrggbb literal is a format error, not a silent alpha drop', () {
      expect(
        () => LinearRgb.fromHex('#ffeae5e1'),
        throwsA(isA<SceneFrameFormatException>()),
      );
      expect(
        () => LinearRgb.fromHex('garbage'),
        throwsA(isA<SceneFrameFormatException>()),
      );
    });

    test('blend interpolates all three components and nothing else', () {
      final LinearRgb from = LinearRgb.fromHex('#eae5e1');
      final LinearRgb to = LinearRgb.fromHex('#11181b');
      expect(from.blend(to, 0), from);
      final LinearRgb full = from.blend(to, 1);
      expect(full.r, closeTo(to.r, 1e-12));
      expect(full.g, closeTo(to.g, 1e-12));
      expect(full.b, closeTo(to.b, 1e-12));
      final LinearRgb half = from.blend(to, 0.5);
      expect(half.r, closeTo((from.r + to.r) / 2, 1e-12));
      expect(half.g, closeTo((from.g + to.g) / 2, 1e-12));
      expect(half.b, closeTo((from.b + to.b) / 2, 1e-12));
      expect(half.toJson().length, 3);
    });
  });

  group('palette helpers — Qt/src/NativeSceneFrame.cpp:110-113', () {
    test('background blends #eae5e1 -> #11181b over the theme', () {
      expect(sceneBackground(0), LinearRgb.fromHex(kBackgroundLightHex));
      // blend(amount: 1) is from + (to - from); the subtraction and addition
      // may round one ulp away from the literal, so the far end is compared
      // per component instead of with LinearRgb's exact ==.
      final LinearRgb dark = sceneBackground(1);
      final LinearRgb darkLiteral = LinearRgb.fromHex(kBackgroundDarkHex);
      expect(dark.r, closeTo(darkLiteral.r, 1e-12));
      expect(dark.g, closeTo(darkLiteral.g, 1e-12));
      expect(dark.b, closeTo(darkLiteral.b, 1e-12));
      final LinearRgb quarter = sceneBackground(0.25);
      final LinearRgb expected =
          LinearRgb.fromHex(kBackgroundLightHex).blend(LinearRgb.fromHex(kBackgroundDarkHex), 0.25);
      expect(quarter, expected);
    });

    test('fog blends #eae5e1 -> #263136 over the theme', () {
      expect(sceneFogColor(0), LinearRgb.fromHex(kFogLightHex));
      final LinearRgb dark = sceneFogColor(1);
      final LinearRgb darkLiteral = LinearRgb.fromHex(kFogDarkHex);
      expect(dark.r, closeTo(darkLiteral.r, 1e-12));
      expect(dark.g, closeTo(darkLiteral.g, 1e-12));
      expect(dark.b, closeTo(darkLiteral.b, 1e-12));
      expect(
        sceneFogColor(1),
        LinearRgb.fromHex('#eae5e1').blend(LinearRgb.fromHex('#263136'), 1),
      );
    });

    test('background and fog are different colours in dark mode', () {
      expect(sceneBackground(1).b, isNot(closeTo(sceneFogColor(1).b, 1e-9)));
    });
  });

  // -------------------------------------------------------------------------
  // Column-major matrices.
  // -------------------------------------------------------------------------
  group('SceneFrame matrices are column-major — NativeSceneFrame.cpp:114-115', () {
    test('identity serialises as the column-major identity', () {
      final SceneFrame frame = SceneFrame.fromQtFrame(
        _minimalQtFrame(),
        viewport: const SceneSize(1920, 1080),
      );
      expect(frame.projection.values.length, 16);
      // index = column * 4 + row
      for (int index = 0; index < 16; index += 1) {
        final double expected = (index % 5 == 0) ? 1.0 : 0.0;
        expect(frame.projection.values[index], expected, reason: 'index $index');
      }
    });

    test('a translation lives in the last column, not the last row', () {
      final Mat4 translation = Mat4(<double>[
        1, 0, 0, 0, //
        0, 1, 0, 0, //
        0, 0, 1, 0, //
        4, 5, 6, 1, //
      ]);
      final Vec3 origin = translation.point(Vec3.zero);
      expect(origin.x, closeTo(4, 1e-12));
      expect(origin.y, closeTo(5, 1e-12));
      expect(origin.z, closeTo(6, 1e-12));
      expect(translation.values[3], 0.0, reason: 'row-major would put 4 here');
      expect(translation.values[12], 4.0);
      expect(translation.values[13], 5.0);
      expect(translation.values[14], 6.0);
    });

    test('compose puts the position in the translation column', () {
      final Mat4 model = Mat4.compose(const Vec3(1.5, -2.5, 3.5), Vec3.zero);
      expect(model.values[12], closeTo(1.5, 1e-12));
      expect(model.values[13], closeTo(-2.5, 1e-12));
      expect(model.values[14], closeTo(3.5, 1e-12));
      final Vec3 origin = model.point(Vec3.zero);
      expect(origin.x, closeTo(1.5, 1e-12));
    });

    test('fromQtFrame keeps the serialised order verbatim', () {
      final List<double> values = <double>[
        for (int index = 0; index < 16; index += 1) index.toDouble(),
      ];
      final Map<String, Object?> source = _minimalQtFrame();
      source['projection'] = values;
      final SceneFrame frame =
          SceneFrame.fromQtFrame(source, viewport: const SceneSize(1920, 1080));
      for (int index = 0; index < 16; index += 1) {
        expect(frame.projection.values[index], values[index], reason: 'index $index');
      }
      final List<Object?> wire = frame.toQtFrame()['projection']! as List<Object?>;
      expect(wire.length, 16);
      for (int index = 0; index < 16; index += 1) {
        expect((wire[index]! as double), values[index]);
      }
      expect((frame.toQtFrame()['view']! as List<Object?>).length, 16);
      expect((frame.toQtFrame()['aoProjection']! as List<Object?>).length, 16);
    });

    test('the model matrix defaults to identity and is never a frame key', () {
      final SceneFrame frame = SceneFrame.fromQtFrame(
        _minimalQtFrame(),
        viewport: const SceneSize(1920, 1080),
      );
      expect(frame.model.values[0], 1.0);
      expect(frame.model.values[12], 0.0);
      expect(frame.toQtFrame().containsKey('model'), isFalse);
    });

    test('projectPoint flips y and rounds to the pixel centre', () {
      final SceneFrame frame = SceneFrame.fromQtFrame(
        _minimalQtFrame(),
        viewport: const SceneSize(1920, 1080),
      );
      // NDC origin is the viewport centre: (1 * 1920 / 2 + 0.5) floored = 960.
      expect(frame.projectPoint(Vec3.zero), <double>[960, 540]);
      // +x right of centre, +y above centre (so smaller pixel y).
      expect(frame.projectPoint(const Vec3(0.5, 0.0, 0.0))[0], 1440);
      expect(frame.projectPoint(const Vec3(0.0, 0.5, 0.0))[1], 270);
      expect(frame.projectPoint(const Vec3(-0.5, -0.5, 0.0)), <double>[480, 810]);
    });

    test('projectPoint uses the model matrix as well', () {
      final SceneFrame frame = SceneFrame.fromQtFrame(
        _minimalQtFrame(),
        viewport: const SceneSize(1920, 1080),
        model: Mat4.compose(const Vec3(0.1, 0, 0), Vec3.zero),
      );
      final List<double> projected = frame.projectPoint(Vec3.zero);
      expect(projected[0], greaterThan(960));
      expect(projected[1], 540);
    });
  });

  // -------------------------------------------------------------------------
  // Colours on the frame.
  // -------------------------------------------------------------------------
  group('SceneFrame colours are alpha-free — NativeSceneFrame.cpp:110-113', () {
    test('background and fogColor serialise with three components', () {
      final SceneFrame frame = SceneFrame.fromQtFrame(
        _minimalQtFrame(),
        viewport: const SceneSize(1920, 1080),
      );
      expect((frame.toQtFrame()['background']! as List<Object?>).length, 3);
      expect((frame.toQtFrame()['fogColor']! as List<Object?>).length, 3);
    });

    test('a four-component background is rejected', () {
      final Map<String, Object?> source = _minimalQtFrame();
      source['background'] = <double>[0.9, 0.8, 0.7, 1.0];
      expect(
        () => SceneFrame.fromQtFrame(source, viewport: const SceneSize(1920, 1080)),
        throwsA(isA<SceneFrameFormatException>()),
      );
    });

    test('a missing colour is a format error, a missing number is not', () {
      final Map<String, Object?> missing = _minimalQtFrame()..remove('fogColor');
      expect(
        () => SceneFrame.fromQtFrame(missing, viewport: const SceneSize(1920, 1080)),
        throwsA(isA<SceneFrameFormatException>()),
      );
      final Map<String, Object?> sparse = _minimalQtFrame()..remove('fogNear');
      final SceneFrame frame =
          SceneFrame.fromQtFrame(sparse, viewport: const SceneSize(1920, 1080));
      expect(frame.fogNear, kDefaultFogNear);
      expect(frame.fogFar, kDefaultFogFar);
      expect(frame.near, kSceneNear);
      expect(frame.far, kSceneFar);
      expect(frame.mode, kFrameModeBoot);
    });
  });

  // -------------------------------------------------------------------------
  // Unknown fields.
  // -------------------------------------------------------------------------
  group('SceneFrame preserves fields it does not type', () {
    test('unknown keys are kept verbatim in extensions', () {
      final Map<String, Object?> source = _minimalQtFrame()
        ..['draws'] = <Object?>[1, 2, 3]
        ..['reference'] = 'Ref-000123'
        ..['pendingAnimations'] = <Object?>['cover']
        ..['culledCards'] = <String, Object?>{'cards': 3}
        ..['returningAgeMax'] = 4.5;
      final SceneFrame frame =
          SceneFrame.fromQtFrame(source, viewport: const SceneSize(1920, 1080));
      expect(frame.extensions.keys.toSet(), <String>{
        'draws',
        'reference',
        'pendingAnimations',
        'culledCards',
        'returningAgeMax',
      });
      expect(frame.extensions['reference'], 'Ref-000123');
      final Map<String, Object?> wire = frame.toQtFrame();
      expect(wire['reference'], 'Ref-000123');
      expect(wire['draws'], <Object?>[1, 2, 3]);
      expect(wire['returningAgeMax'], 4.5);
      expect((wire['culledCards']! as Map<String, Object?>)['cards'], 3);
    });

    test('every input key survives a round trip', () {
      final Map<String, Object?> source = _minimalQtFrame()
        ..['draws'] = <Object?>[]
        ..['focus'] = <double>[0, 1, 2]
        ..['aperture'] = 0.4
        ..['boot'] = 1.0
        ..['viewerState'] = <String, Object?>{'transition': 'closed'};
      final SceneFrame frame =
          SceneFrame.fromQtFrame(source, viewport: const SceneSize(1920, 1080));
      final Map<String, Object?> wire = frame.toQtFrame();
      for (final String key in source.keys) {
        expect(wire.containsKey(key), isTrue, reason: 'lost $key');
      }
      expect(wire['aperture'], 0.4);
      expect(wire['boot'], 1.0);
    });

    test('a typed value wins over an extension of the same name', () {
      final SceneFrame frame = SceneFrame(
        projection: Mat4(),
        view: Mat4(),
        background: sceneBackground(0),
        fogColor: sceneFogColor(0),
        viewport: const SceneSize(1920, 1080),
        mode: kFrameModeDetail,
        extensions: <String, Object?>{'mode': 'archive', 'draws': 7},
      );
      final Map<String, Object?> wire = frame.toQtFrame();
      expect(wire['mode'], kFrameModeDetail);
      expect(wire['draws'], 7);
    });

    test('copyWith keeps extensions and can replace them', () {
      final SceneFrame frame = SceneFrame(
        projection: Mat4(),
        view: Mat4(),
        background: sceneBackground(0),
        fogColor: sceneFogColor(0),
        viewport: const SceneSize(1920, 1080),
        extensions: <String, Object?>{'draws': 7},
      );
      final SceneFrame derived = frame.copyWith(mode: kFrameModeArchive);
      expect(derived.mode, kFrameModeArchive);
      expect(derived.extensions['draws'], 7);
      expect(identical(derived.projection, frame.projection), isTrue);
      final SceneFrame replaced =
          derived.copyWith(extensions: const <String, Object?>{'draws': 8});
      expect(replaced.extensions['draws'], 8);
    });

    test('extensions are immutable', () {
      final SceneFrame frame = SceneFrame(
        projection: Mat4(),
        view: Mat4(),
        background: sceneBackground(0),
        fogColor: sceneFogColor(0),
        viewport: const SceneSize(1920, 1080),
      );
      expect(
        () => frame.extensions['x'] = 1,
        throwsUnsupportedError,
      );
    });
  });

  // -------------------------------------------------------------------------
  // Actor identity and the current record.
  // -------------------------------------------------------------------------
  group('SceneFrame actor identity — NativeSceneFrame.cpp:143-159', () {
    Map<String, Object?> actorFrame() => _minimalQtFrame()
      ..['mode'] = kFrameModeDetail
      ..['selected'] = 2
      ..['actors'] = <Object?>[
        <String, Object?>{'id': 2, 'musicKey': 'track-2', 'selected': true, 'shadowOnly': false},
        <String, Object?>{'id': 5, 'musicKey': null, 'selected': false, 'shadowOnly': true},
      ];

    test('actors parse with their selected and shadowOnly flags', () {
      final SceneFrame frame =
          SceneFrame.fromQtFrame(actorFrame(), viewport: const SceneSize(1920, 1080));
      expect(frame.actors.length, 2);
      expect(frame.actors.first.id, 2);
      expect(frame.actors.first.musicKey, 'track-2');
      expect(frame.actors.first.selected, isTrue);
      expect(frame.actors.last.musicKey, isNull);
      expect(frame.actors.last.shadowOnly, isTrue);
      expect(frame.selectedActor?.id, 2);
      expect(frame.isDetail, isTrue);
      expect(frame.selected, 2);
    });

    test('a null musicKey keeps its key on the way back out', () {
      final SceneFrame frame =
          SceneFrame.fromQtFrame(actorFrame(), viewport: const SceneSize(1920, 1080));
      final List<Object?> wire = frame.toQtFrame()['actors']! as List<Object?>;
      final Map<String, Object?> second = wire[1]! as Map<String, Object?>;
      expect(second.containsKey('musicKey'), isTrue);
      expect(second['musicKey'], isNull);
    });

    test('an empty actors list is not emitted', () {
      final Map<String, Object?> source = _minimalQtFrame()..['actors'] = <Object?>[];
      final SceneFrame frame =
          SceneFrame.fromQtFrame(source, viewport: const SceneSize(1920, 1080));
      expect(frame.actors, isEmpty);
      expect(frame.toQtFrame().containsKey('actors'), isFalse);
    });

    test('current is an envelope fact and is never a frame key', () {
      final SceneFrame frame = SceneFrame.fromQtFrame(
        actorFrame(),
        viewport: const SceneSize(1920, 1080),
        current: const SceneCurrent(musicKey: 'track-2', index: 4),
      );
      expect(frame.current?.musicKey, 'track-2');
      expect(frame.current?.index, 4);
      expect(frame.toQtFrame().containsKey('current'), isFalse);
      final SceneFrame cleared = frame.copyWith(clearCurrent: true);
      expect(cleared.current, isNull);
      final SceneFrame kept = frame.copyWith(mode: kFrameModeArchive);
      expect(kept.current?.musicKey, 'track-2');
      expect(kept.mode, kFrameModeArchive);
    });
  });

  // -------------------------------------------------------------------------
  // Frame clock.
  // -------------------------------------------------------------------------
  group('AnimationClock — NativeViewer.cpp:225-226', () {
    test('the first frame uses the 60 Hz fallback step', () {
      final AnimationClock clock = AnimationClock(time: 10);
      expect(clock.hasSample, isFalse);
      expect(clock.advance(10.5), closeTo(kFirstFrameStep, 1e-12));
      expect(clock.hasSample, isTrue);
      expect(clock.last, 10.5);
    });

    test('later frames report their delta', () {
      final AnimationClock clock = AnimationClock();
      clock.advance(1.0);
      expect(clock.advance(1.01), closeTo(0.01, 1e-12));
    });

    test('a long gap is clamped to 50 ms', () {
      final AnimationClock clock = AnimationClock();
      clock.advance(1.0);
      expect(clock.advance(9.0), closeTo(kMaxFrameStep, 1e-12));
      expect(kMaxFrameStep, 0.05);
    });

    test('a backwards clock keeps its negative delta, like std::min', () {
      final AnimationClock clock = AnimationClock();
      clock.advance(1.0);
      expect(clock.advance(0.9), closeTo(-0.1, 1e-12));
    });

    test('seek moves the time without touching the delta bookkeeping', () {
      final AnimationClock clock = AnimationClock();
      clock.advance(1.0);
      clock.seek(5.0);
      expect(clock.time, 5.0);
      expect(clock.last, 1.0);
      expect(clock.advance(5.0), closeTo(kMaxFrameStep, 1e-12));
    });

    test('rebase re-arms the fallback step', () {
      final AnimationClock clock = AnimationClock();
      clock.advance(1.0);
      clock.rebase();
      expect(clock.hasSample, isFalse);
      expect(clock.advance(7.0), closeTo(kFirstFrameStep, 1e-12));
    });
  });

  // -------------------------------------------------------------------------
  // Wall-clock detail fade.
  // -------------------------------------------------------------------------
  group('DetailFadeClock — NativeHud.cpp:242-251, 280-288', () {
    test('the latch is taken once and survives repeated samples', () {
      final DetailFadeClock fade = DetailFadeClock();
      expect(fade.isArmed, isFalse);
      fade.sample(inDetail: true, wallMs: 1000);
      expect(fade.isArmed, isTrue);
      expect(fade.enterWallMs, 1000);
      fade.sample(inDetail: true, wallMs: 1200);
      expect(fade.enterWallMs, 1000, reason: 're-entering the page must not restart the fade');
    });

    test('leaving the detail page clears the latch', () {
      final DetailFadeClock fade = DetailFadeClock();
      fade.sample(inDetail: true, wallMs: 1000);
      fade.sample(inDetail: false, wallMs: 1100);
      expect(fade.isArmed, isFalse);
      expect(fade.enterWallMs, isNull);
      expect(fade.opacity(0.25, wallMs: 1200), 0.25,
          reason: 'outside the page Qt never computes the ramp');
    });

    test('the wall clock reaches 1 after exactly 500 ms', () {
      final DetailFadeClock fade = DetailFadeClock();
      fade.sample(inDetail: true, wallMs: 1000);
      expect(fade.opacity(0, wallMs: 1000), 0.0);
      expect(fade.opacity(0, wallMs: 1250), closeTo(0.5, 1e-12));
      expect(fade.opacity(0, wallMs: 1500), 1.0);
      expect(fade.opacity(0, wallMs: 9000), 1.0);
      expect(kDetailFadeSeconds, 0.5);
    });

    test('the ramp is the smoothstep the HUD documents', () {
      final DetailFadeClock fade = DetailFadeClock();
      fade.sample(inDetail: true, wallMs: 0);
      for (final int elapsed in <int>[50, 100, 250, 400, 500]) {
        final double wall = elapsed / 500;
        final double eased = wall * wall * (3 - 2 * wall);
        expect(fade.opacity(0, wallMs: elapsed), closeTo(eased, 1e-12),
            reason: 'elapsed $elapsed');
      }
    });

    test('the pseudo clock wins whenever it is ahead', () {
      final DetailFadeClock fade = DetailFadeClock();
      fade.sample(inDetail: true, wallMs: 0);
      expect(fade.opacity(0.8, wallMs: 100), 0.8);
      expect(fade.opacity(0.8, wallMs: 5000), 1.0);
    });

    test('convergence: after 500 ms the max is the wall clock', () {
      final DetailFadeClock fade = DetailFadeClock();
      fade.sample(inDetail: true, wallMs: 2000);
      double opacity = 0;
      for (int elapsed = 0; elapsed <= 500; elapsed += 25) {
        opacity = fade.opacity(0.1, wallMs: 2000 + elapsed);
        expect(opacity, greaterThanOrEqualTo(0.1));
      }
      expect(opacity, 1.0);
    });
  });

  // -------------------------------------------------------------------------
  // Viewer state machine.
  // -------------------------------------------------------------------------
  group('ViewerState opening — NativeViewer.cpp:39-64', () {
    test('a closed viewer ignores updates', () {
      final ViewerState state = ViewerState();
      expect(state.isOpen, isFalse);
      expect(state.transition, ViewerTransition.closed);
      expect(state.update(1000), isNull);
      expect(state.transition, ViewerTransition.closed);
      expect(state.isOpen, isFalse);
    });

    test('open latches the 0.38 s pending window and rebases the clock', () {
      final ViewerState state = ViewerState(ready: true);
      state.open(1000);
      expect(state.isOpen, isTrue);
      expect(state.pending, isTrue);
      expect(state.transition, ViewerTransition.opening);
      expect(state.pendingUntil, closeTo(1000.38, 1e-12));
      expect(state.surface, ViewerSurface.clear);
      expect(state.clarity, 1.0);
      expect(state.clock.last, 0.0, reason: 'm_last = 0 in NativeViewer::open');
      expect(kOpeningSeconds, 0.38);
    });

    test('the pending window ends at pendingUntil, not before', () {
      final ViewerState state = ViewerState(ready: true);
      state.open(1000);
      expect(state.update(1000.37), isNull);
      expect(state.transition, ViewerTransition.opening);
      expect(state.pending, isTrue);
      expect(state.update(1000.38), isNull);
      expect(state.transition, ViewerTransition.open);
      expect(state.pending, isFalse);
    });

    test('opening again while open is a no-op', () {
      final ViewerState state = ViewerState(ready: true);
      state.open(1000);
      state.act(ViewerAction.frosted, 1000);
      state.open(2000, ready: false);
      expect(state.pendingUntil, closeTo(1000.38, 1e-12));
      expect(state.targetClarity, 0.0, reason: 'the second open must not reset the surface');
      expect(state.clock.time, 1000);
      expect(state.ready, isTrue);
    });
  });

  group('ViewerState closing — NativeViewer.cpp:108-130, 208-236', () {
    test('close latches its end time and completes on that frame', () {
      final ViewerState state = ViewerState(ready: true);
      state.open(1000);
      state.act(ViewerAction.close, 2000);
      expect(state.isClosing, isTrue);
      expect(state.transition, ViewerTransition.closing);
      expect(state.closeAt, closeTo(2000.22, 1e-12));
      expect(state.pending, isTrue);
      expect(state.update(2000.21), isNull);
      expect(state.isOpen, isTrue);
      final ViewerCloseOutcome? outcome = state.update(2000.22);
      expect(outcome, isNotNull);
      final ViewerCloseOutcome closed = outcome!;
      expect(closed.resumeMode, kFrameModeDetail);
      expect(closed.time, closeTo(2000.22, 1e-12));
      expect(state.isOpen, isFalse);
      expect(state.isClosing, isFalse);
      expect(state.pending, isFalse);
      expect(state.transition, ViewerTransition.closed);
      expect(state.ready, isFalse, reason: 'm_ready = false on close');
      expect(kClosingSeconds, 0.22);
    });

    test('a repeated close while closing is idempotent', () {
      final ViewerState state = ViewerState(ready: true);
      state.open(1000);
      state.act(ViewerAction.close, 2000);
      state.act(ViewerAction.close, 2000.1);
      state.act(ViewerAction.close, 2010);
      expect(state.closeAt, closeTo(2000.22, 1e-12), reason: 'closeAt must not be re-latched');
      expect(state.transition, ViewerTransition.closing);
      expect(state.update(2000.22)?.resumeMode, kFrameModeDetail);
      expect(state.isOpen, isFalse);
      expect(state.update(2000.23), isNull, reason: 'closed is closed');
    });

    test('other actions are ignored while closing', () {
      final ViewerState state = ViewerState(ready: true);
      state.open(1000);
      state.act(ViewerAction.close, 1000);
      state.act(ViewerAction.frosted, 1000.1);
      state.act(ViewerAction.explode, 1000.1);
      state.act(ViewerAction.reset, 1000.1);
      expect(state.surface, ViewerSurface.clear);
      expect(state.targetClarity, 1.0);
      expect(state.targetSpread, 0.0);
      expect(state.resetting, isFalse);
    });

    test('actions require readiness, close does not', () {
      final ViewerState state = ViewerState(ready: false);
      state.open(1000);
      state.act(ViewerAction.frosted, 1000);
      expect(state.targetClarity, 1.0, reason: 'no meshes, no surface change');
      state.key('Escape', 1000);
      expect(state.isClosing, isTrue);
      expect(state.update(1000.22)?.resumeMode, kFrameModeDetail);
    });

    test('a reduced-motion close completes on the same frame', () {
      final ViewerState state = ViewerState(ready: true, reduced: true);
      state.open(1000);
      expect(state.pendingUntil, 1000);
      expect(state.update(1000)?.resumeMode, isNull,
          reason: 'still open, the close has not been requested');
      state.act(ViewerAction.close, 1000);
      expect(state.closeAt, 1000);
      final ViewerCloseOutcome? outcome = state.update(1000);
      expect(outcome, isNotNull);
      expect(state.isOpen, isFalse);
    });
  });

  group('ViewerState reset keeps the clock — NativeViewer.cpp:77-98', () {
    test('reset does not touch the frame clock', () {
      final ViewerState state = ViewerState(ready: true);
      state.open(5000);
      state.update(5000.1);
      expect(state.clock.last, closeTo(5000.1, 1e-12));
      state.act(ViewerAction.reset, 5000.1);
      expect(state.resetting, isTrue);
      expect(state.resetElapsed, 0.0);
      expect(state.clock.time, closeTo(5000.1, 1e-12));
      expect(state.clock.last, closeTo(5000.1, 1e-12));
      state.update(5000.15);
      expect(state.resetElapsed, closeTo(0.05, 1e-12));
      expect(state.clock.last, closeTo(5000.15, 1e-12));
    });

    test('the reset interpolation finishes after 0.56 s of frames', () {
      final ViewerState state = ViewerState(ready: true);
      state.open(1000);
      state.act(ViewerAction.reset, 1000);
      expect(state.resetting, isTrue);
      int frames = 0;
      double time = 1000;
      while (state.resetting && frames < 40) {
        time += 0.05;
        state.update(time);
        frames += 1;
      }
      expect(state.resetting, isFalse);
      expect(frames, 12, reason: '0.56 s / 0.05 s per frame rounds up');
      expect(state.resetElapsed, greaterThanOrEqualTo(kResetSeconds));
      expect(kResetSeconds, 0.56);
    });

    test('Home resets only when the overlay is ready', () {
      final ViewerState state = ViewerState(ready: false);
      state.open(1000);
      state.key('Home', 1000);
      expect(state.resetting, isFalse);
      state.ready = true;
      state.key('Home', 1000);
      expect(state.resetting, isTrue);
      state.interrupt();
      expect(state.resetting, isFalse);
    });

    test('camera keys are not this atom and change nothing', () {
      final ViewerState state = ViewerState(ready: true);
      state.open(1000);
      for (final String key in <String>['+', '=', '-', 'ArrowLeft', 'ArrowUp']) {
        state.key(key, 1000);
      }
      expect(state.resetting, isFalse);
      expect(state.isClosing, isFalse);
      expect(state.targetClarity, 1.0);
      expect(state.clock.last, 0.0);
    });

    test('a reduced-motion reset is immediate', () {
      final ViewerState state = ViewerState(ready: true, reduced: true);
      state.open(1000);
      state.act(ViewerAction.reset, 1000);
      expect(state.resetting, isFalse);
    });
  });

  group('ViewerState clarity and frosted — NativeViewer.cpp:119-127', () {
    test('frosted and clear are mutually exclusive and reversible', () {
      final ViewerState state = ViewerState(ready: true);
      state.open(1000);
      expect(state.surface, ViewerSurface.clear);
      expect(state.targetClarity, 1.0);
      state.act(ViewerAction.frosted, 1000);
      expect(state.surface, ViewerSurface.frosted);
      expect(state.targetClarity, 0.0);
      state.act(ViewerAction.clear, 1000);
      expect(state.surface, ViewerSurface.clear);
      expect(state.targetClarity, 1.0);
      expect(state.transition, ViewerTransition.opening);
    });

    test('the clarity spring settles exactly on its target', () {
      final ViewerState state = ViewerState(ready: true);
      state.open(1000);
      state.act(ViewerAction.frosted, 1000);
      double time = 1000;
      for (int frame = 0; frame < 40; frame += 1) {
        time += 0.05;
        state.update(time);
      }
      expect(state.clarity, 0.0, reason: 'the 0.0001 / 0.001 thresholds snap it');
      expect(state.claritySpring.velocity, 0.0);
      state.act(ViewerAction.clear, time);
      for (int frame = 0; frame < 40; frame += 1) {
        time += 0.05;
        state.update(time);
      }
      expect(state.clarity, 1.0);
    });

    test('the spring follows the Qt recurrence with the frame step', () {
      final ViewerState state = ViewerState(ready: true);
      state.open(1000);
      state.act(ViewerAction.frosted, 1000);
      final List<double> expected = _damped(1, 0, 0, kClarityRate, kFirstFrameStep);
      state.update(1000.5);
      expect(state.clarity, closeTo(expected[0], 1e-12),
          reason: 'the first frame must advance by 1/60 s, not by the 0.5 s gap');
      expect(state.claritySpring.velocity, closeTo(expected[1], 1e-12));
    });

    test('reduced motion snaps the clarity instead of animating it', () {
      final ViewerState state = ViewerState(ready: true, reduced: true);
      state.open(1000);
      state.act(ViewerAction.frosted, 1000);
      state.update(1000.01);
      expect(state.clarity, 0.0);
      state.act(ViewerAction.clear, 1000.02);
      state.update(1000.02);
      expect(state.clarity, 1.0);
    });

    test('setReduced collapses the pending window and snaps the springs', () {
      final ViewerState state = ViewerState(ready: true);
      state.open(1000);
      state.act(ViewerAction.frosted, 1000);
      state.update(1000.05);
      expect(state.clarity, lessThan(1.0));
      expect(state.clarity, greaterThan(0.0));
      state.setReduced(true);
      expect(state.reduced, isTrue);
      expect(state.pendingUntil, closeTo(1000.05, 1e-12));
      expect(state.clarity, 0.0);
      expect(state.claritySpring.velocity, 0.0);
      expect(state.pending, isFalse);
    });
  });

  group('ViewerState spread and wire output — NativeViewer.cpp:276-355', () {
    test('explode and assemble move only the spread', () {
      final ViewerState state = ViewerState(ready: true);
      state.open(1000);
      state.act(ViewerAction.explode, 1000);
      expect(state.targetSpread, 1.0);
      expect(state.exploded, isTrue);
      expect(state.targetClarity, 1.0);
      state.act(ViewerAction.assemble, 1000);
      expect(state.targetSpread, 0.0);
      expect(state.exploded, isFalse);
    });

    test('exploded is a string in viewerState, not a JSON boolean', () {
      final ViewerState state = ViewerState(ready: true);
      state.open(1000);
      final Map<String, Object?> closedState = state.toViewerStateJson();
      expect(closedState['exploded'], isA<String>());
      expect(closedState['exploded'], 'false');
      state.act(ViewerAction.explode, 1000);
      expect(state.toViewerStateJson()['exploded'], 'true');
    });

    test('viewerState carries the wire strings and sorted compact stats', () {
      final ViewerState state = ViewerState(ready: true);
      state.open(1000);
      state.act(ViewerAction.frosted, 1000);
      final Map<String, Object?> json = state.toViewerStateJson(
        stats: <String, Object?>{'ready': true, 'clarity': 0.5},
      );
      expect(json['transition'], 'opening');
      expect(json['surface'], 'frosted');
      expect(json['stats'], isA<String>());
      expect(json['stats'], '{"clarity":0.5,"ready":true}');
      state.update(1000.38);
      expect(state.toViewerStateJson()['transition'], 'open');
      state.act(ViewerAction.close, 1000.38);
      expect(state.toViewerStateJson()['transition'], 'closing');
    });

    test('statsSnapshot fills only what this machine knows', () {
      final ViewerState state = ViewerState(ready: true);
      state.open(1000);
      final Map<String, Object?> stats = state.statsSnapshot();
      expect(stats['ready'], isTrue);
      expect(stats['clarity'], 1.0);
      expect(stats['targetClarity'], 1.0);
      expect(stats['spread'], 0.0);
      expect(stats['resetting'], isFalse);
      expect(stats.containsKey('cameraPosition'), isFalse,
          reason: 'the camera belongs to another atom');
    });

    test('applyWire accepts the Qt action strings and ignores others', () {
      final ViewerState state = ViewerState(ready: true);
      state.open(1000);
      expect(state.applyWire('frosted', 1000), isTrue);
      expect(state.surface, ViewerSurface.frosted);
      expect(state.applyWire('nope', 1000), isFalse);
      expect(state.applyWire('clear', 1000), isTrue);
      expect(state.surface, ViewerSurface.clear);
      for (final ViewerAction action in ViewerAction.values) {
        expect(ViewerAction.fromWire(action.wire), action);
      }
      expect(ViewerAction.fromWire('CLOSE'), isNull);
      expect(ViewerTransition.fromWire('nope'), isNull);
      expect(ViewerSurface.fromWire('clear'), ViewerSurface.clear);
    });

    test('toString is informative without leaking state mutations', () {
      final ViewerState state = ViewerState(ready: true);
      state.open(1000);
      final String text = state.toString();
      expect(text.contains('opening'), isTrue);
      expect(text.contains('clear'), isTrue);
    });
  });

  // -------------------------------------------------------------------------
  // The two halves talking to each other.
  // -------------------------------------------------------------------------
  group('frame and viewer together', () {
    test('viewerState survives a frame round trip as an extension', () {
      final ViewerState state = ViewerState(ready: true);
      state.open(1000);
      final SceneFrame frame = SceneFrame.fromQtFrame(
        _minimalQtFrame()
          ..['viewer'] = true
          ..['viewerReady'] = true
          ..['viewerState'] = state.toViewerStateJson(stats: state.statsSnapshot())
          ..['mode'] = kFrameModeDetail,
        viewport: const SceneSize(1920, 1080),
      );
      expect(frame.viewer, isTrue);
      expect(frame.viewerReady, isTrue);
      expect(frame.mode, kFrameModeDetail);
      final Map<String, Object?> again = frame.toQtFrame();
      final Map<String, Object?> viewerState =
          again['viewerState']! as Map<String, Object?>;
      expect(viewerState['transition'], 'opening');
      expect(viewerState['exploded'], 'false');
      expect(viewerState['stats'], isA<String>());
    });

    test('closing the viewer hands the detail page back', () {
      final ViewerState state = ViewerState(ready: true, resumeMode: kFrameModeDetail);
      state.open(1000);
      state.act(ViewerAction.close, 2000);
      final ViewerCloseOutcome? outcome = state.update(2000.22);
      expect(outcome?.resumeMode, kFrameModeDetail);
      expect(outcome?.time, closeTo(2000.22, 1e-12));
      final ViewerCloseOutcome closed = outcome!;
      final SceneFrame frame = SceneFrame(
        projection: Mat4(),
        view: Mat4(),
        background: sceneBackground(0),
        fogColor: sceneFogColor(0),
        viewport: const SceneSize(1920, 1080),
        mode: closed.resumeMode,
        time: closed.time,
        viewer: state.isOpen,
      );
      expect(frame.isDetail, isTrue);
      expect(frame.viewer, isFalse);
      expect(frame.toQtFrame()['time'], closeTo(2000.22, 1e-12));
    });
  });
}
