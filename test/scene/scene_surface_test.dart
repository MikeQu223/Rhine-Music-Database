/// Companion evidence for lib/scene/scene_surface.dart.
///
/// STATUS: written, deliberately NOT executed. The atom forbids running any
/// flutter/dart build, test, analyze or run, so this file is a static
/// specification of the expected numbers, not a passed test run. It imports
/// package:flutter_test because this repository has no package:test entry in
/// pubspec.yaml (the same rule every existing test under test/scene follows);
/// the library under test stays pure Dart.
///
/// Source of truth (base 3aa6706f91ae7c3c963a3866f27d28e8c63b20fd):
/// - Qt/src/NativeSceneInput.cpp:116-200 (browse pan, slop, detail yaw)
/// - Qt/src/NativeSceneCamera.cpp:84-107 (1 - exp(-5 dt) pursuit)
/// - Qt/src/SceneDrag.cpp:64-100 (release velocity, friction, snap)
/// - Qt/src/NativeSceneUpdate.cpp:48,64-65 (0.05 s step, rotation blend)
/// - Qt/src/SceneLifetimePolicy.h:31-38 (returnAngleStep)
library;

import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:rhine_music_database/scene/scene_frame.dart';
import 'package:rhine_music_database/scene/scene_math.dart';
import 'package:rhine_music_database/scene/scene_surface.dart';

const SceneSize _viewport = SceneSize(1920, 1080);
const Vec3 _eye = Vec3(0, 2, 20);
const Vec3 _aim = Vec3.zero;

SceneFrame _frame({
  String mode = kFrameModeArchive,
  double detail = 0,
  bool viewer = false,
  Vec3 eye = _eye,
  Vec3 aim = _aim,
}) {
  final Mat4 view = Mat4.camera(eye, aim).inverse();
  return SceneFrame(
    projection: Mat4.perspective(
      kViewerFov,
      _viewport.aspect,
      kViewerNear,
      kViewerFar,
    ),
    view: view,
    background: LinearRgb.backgroundLight,
    fogColor: LinearRgb.fogLight,
    viewport: _viewport,
    mode: mode,
    detail: detail,
    eye: eye,
    viewer: viewer,
  );
}

SceneSurface _surface({
  String mode = kFrameModeArchive,
  double detail = 0,
  double reduced = 0,
  bool viewer = false,
  SceneCell? selectedCell,
  Vec3 eye = _eye,
}) {
  return SceneSurface(
    frame: _frame(mode: mode, detail: detail, viewer: viewer, eye: eye),
    size: _viewport,
    reducedMotion: reduced,
    selectedCell: selectedCell,
  );
}

void _expectFiniteCamera(SceneCamera camera) {
  expect(camera.isFinite, isTrue);
  expect(camera.eye.x.isFinite, isTrue);
  expect(camera.eye.y.isFinite, isTrue);
  expect(camera.eye.z.isFinite, isTrue);
  expect(camera.aim.x.isFinite, isTrue);
  expect(camera.aim.y.isFinite, isTrue);
  expect(camera.aim.z.isFinite, isTrue);
  expect(camera.fov.isFinite, isTrue);
}

void main() {
  group('SceneCamera.fromFrame', () {
    test('rebuilds the eye, the unit aim and the fov', () {
      final SceneFrame frame = _frame();
      final SceneCamera camera = SceneCamera.fromFrame(frame);
      expect(camera.eye.x, closeTo(0, 1e-9));
      expect(camera.eye.y, closeTo(2, 1e-9));
      expect(camera.eye.z, closeTo(20, 1e-9));
      final Vec3 forward = (_aim - _eye).normalized();
      expect(camera.aim.x, closeTo(camera.eye.x + forward.x, 1e-9));
      expect(camera.aim.y, closeTo(camera.eye.y + forward.y, 1e-9));
      expect(camera.aim.z, closeTo(camera.eye.z + forward.z, 1e-9));
      expect((camera.aim - camera.eye).length, closeTo(1, 1e-9));
      expect(camera.forward.x, closeTo(forward.x, 1e-9));
      expect(camera.forward.y, closeTo(forward.y, 1e-9));
      expect(camera.forward.z, closeTo(forward.z, 1e-9));
      expect(camera.fov, closeTo(kViewerFov, 1e-9));
      _expectFiniteCamera(camera);
      for (int index = 0; index < 16; index += 1) {
        expect(
          camera.view.values[index],
          closeTo(frame.view.values[index], 1e-9),
        );
      }
    });

    test('falls back to frame.eye when the view is singular', () {
      final SceneFrame frame = SceneFrame(
        projection: Mat4.perspective(
          kViewerFov,
          _viewport.aspect,
          kViewerNear,
          kViewerFar,
        ),
        view: Mat4(List<double>.filled(16, 0)),
        background: LinearRgb.backgroundLight,
        fogColor: LinearRgb.fogLight,
        viewport: _viewport,
        eye: const Vec3(1, 2, 3),
      );
      final SceneCamera camera = SceneCamera.fromFrame(frame);
      expect(camera.eye, const Vec3(1, 2, 3));
      expect(camera.fov, closeTo(kViewerFov, 1e-9));
      _expectFiniteCamera(camera);
    });

    test('translated moves eye and aim together and keeps the direction', () {
      final SceneCamera camera = SceneCamera.fromFrame(_frame());
      final SceneCamera moved = camera.translated(const Vec3(-52, 0, 0));
      expect(moved.eye.x - camera.eye.x, closeTo(-52, 1e-12));
      expect(moved.eye.y, closeTo(camera.eye.y, 1e-12));
      expect(moved.eye.z, closeTo(camera.eye.z, 1e-12));
      expect(moved.forward.x, closeTo(camera.forward.x, 1e-12));
      expect(moved.forward.y, closeTo(camera.forward.y, 1e-12));
      expect(moved.forward.z, closeTo(camera.forward.z, 1e-12));
      expect(moved.fov, camera.fov);
    });
  });

  group('camera pursuit', () {
    test('converges monotonically to the drag target without NaN', () {
      final SceneSurface surface = _surface();
      surface.pointer('pointerdown', 960, 540);
      surface.pointer('pointermove', 980, 540);
      final Vec3 target = surface.targetCamera.eye;
      expect((target - surface.camera.eye).length, closeTo(104, 1e-9));
      double previous = (target - surface.camera.eye).length;
      for (int frame = 0; frame < 240; frame += 1) {
        surface.advance(1 / 60);
        _expectFiniteCamera(surface.camera);
        final double distance = (target - surface.camera.eye).length;
        expect(distance, lessThanOrEqualTo(previous + 1e-12));
        previous = distance;
      }
      expect(previous, lessThan(1e-6));
      expect(surface.camera.eye.x, closeTo(-104, 1e-4));
      expect(surface.camera.fov, closeTo(kViewerFov, 1e-9));
    });

    test('uses 1 - exp(-5 dt) for the first pursuit step', () {
      final SceneSurface surface = _surface();
      surface.pointer('pointerdown', 0, 0);
      surface.pointer('pointermove', 10, 0);
      final Vec3 start = surface.camera.eye;
      final Vec3 target = surface.targetCamera.eye;
      expect(target.x - start.x, closeTo(-52, 1e-9));
      surface.advance(0.1);
      final double blend =
          1 - math.exp(-kSurfaceCameraBlendRate * kSurfaceMaxStep);
      expect(
        surface.camera.eye.x,
        closeTo(start.x + (target.x - start.x) * blend, 1e-12),
      );
      expect(surface.camera.eye.y, closeTo(start.y, 1e-12));
      expect(surface.camera.eye.z, closeTo(start.z, 1e-12));
    });

    test('reduced motion snaps the camera in one advance', () {
      final SceneSurface surface = _surface(reduced: 1);
      surface.pointer('pointerdown', 0, 0);
      surface.pointer('pointermove', 10, 0);
      surface.advance(1 / 60);
      expect(surface.camera.eye.x, closeTo(surface.targetCamera.eye.x, 1e-12));
      expect(surface.camera.eye.y, closeTo(surface.targetCamera.eye.y, 1e-12));
      expect(surface.camera.eye.z, closeTo(surface.targetCamera.eye.z, 1e-12));
      expect(surface.camera.fov, closeTo(surface.targetCamera.fov, 1e-12));
    });

    test('clamps reduced motion to 0..1 and maps NaN to 0', () {
      expect(_surface(reduced: 4).reducedMotion, 1);
      expect(_surface(reduced: -2).reducedMotion, 0);
      expect(_surface(reduced: double.nan).reducedMotion, 0);
      expect(_surface(reduced: 0.5).reducedMotion, 0.5);
    });

    test('a frame arriving mid-drag does not teleport the target', () {
      final SceneSurface surface = _surface();
      surface.pointer('pointerdown', 100, 100);
      surface.pointer('pointermove', 120, 100);
      final Vec3 target = surface.targetCamera.eye;
      surface.setFrame(_frame(eye: const Vec3(100, 2, 20)));
      expect(surface.targetCamera.eye.x, closeTo(target.x, 1e-12));
      expect(surface.camera.eye.x, closeTo(0, 1e-12));
    });
  });

  group('archive browse drag', () {
    test('accumulates lane += dx * 5.2 and row -= dy * 0.62', () {
      final SceneSurface surface = _surface();
      expect(surface.size, _viewport);
      expect(surface.frame.mode, kFrameModeArchive);
      surface.pointer('pointerdown', 100, 100);
      expect(surface.dragging, isTrue);
      expect(surface.browsing, isTrue);
      expect(surface.rotating, isFalse);
      surface.pointer('pointermove', 110, 90);
      expect(surface.dragLane, closeTo(52, 1e-9));
      expect(surface.dragRow, closeTo(6.2, 1e-9));
      surface.pointer('pointermove', 130, 100);
      expect(surface.dragLane, closeTo(156, 1e-9));
      expect(surface.dragRow, closeTo(0, 1e-9));
    });

    test('pointerup snaps a reduced drag to the nearest grid', () {
      final SceneSurface surface = _surface(reduced: 1);
      surface.pointer('pointerdown', 960, 540);
      surface.pointer('pointermove', 972.5, 543.1);
      expect(surface.dragLane, closeTo(65, 1e-9));
      expect(surface.dragRow, closeTo(-1.922, 1e-9));
      surface.pointer('pointerup', 972.5, 543.1);
      expect(surface.dragging, isFalse);
      expect(surface.browsing, isFalse);
      expect(surface.momentumActive, isFalse);
      expect(surface.dragLane, closeTo(67.6, 1e-9));
      expect(surface.dragRow, closeTo(-1.86, 1e-9));
      expect(surface.selectedCell, isNull);
    });

    test('pointerup releases momentum that settles on the grid', () {
      final SceneSurface surface = _surface();
      surface.pointer('pointerdown', 0, 0);
      surface.pointer('pointermove', 10, 0);
      surface.pointer('pointerup', 10, 0);
      expect(surface.dragging, isFalse);
      expect(surface.momentumActive, isTrue);
      for (int frame = 0; frame < 1200 && surface.momentumActive; frame += 1) {
        surface.advance(1 / 60);
        _expectFiniteCamera(surface.camera);
      }
      expect(surface.momentumActive, isFalse);
      for (int frame = 0; frame < 200; frame += 1) {
        surface.advance(1 / 60);
      }
      final double laneUnits = surface.dragLane / kLanePitch;
      final double rowUnits = surface.dragRow / kRowPitch;
      expect(laneUnits, closeTo(laneUnits.roundToDouble(), 1e-9));
      expect(rowUnits, closeTo(rowUnits.roundToDouble(), 1e-9));
      expect(
        (surface.camera.eye - surface.targetCamera.eye).length,
        lessThan(1e-4),
      );
    });

    test('a tap selects the nearest cell and pans the track onto it', () {
      final SceneSurface surface = _surface();
      surface.pointer('pointerdown', 960, 540);
      surface.pointer('pointerup', 960, 540);
      expect(surface.selectedCell, isNotNull);
      final SceneCell picked = surface.selectedCell!;
      expect(picked.lane, 2);
      expect(picked.row, -29);
      expect(surface.dragLane, closeTo((picked.lane - 2) * kLanePitch, 1e-9));
      expect(surface.dragRow, closeTo(-(picked.row - 12) * kRowPitch, 1e-9));
      expect(surface.momentumActive, isFalse);
    });

    test('panning keeps the selected cell; only a tap replaces it', () {
      final SceneSurface surface =
          _surface(selectedCell: const SceneCell(4, 15));
      surface.advance(1 / 60);
      expect(surface.selectedCell!.lane, 4);
      expect(surface.selectedCell!.row, 15);
      surface.pointer('pointerdown', 100, 100);
      surface.pointer('pointermove', 200, 100);
      surface.pointer('pointerup', 200, 100);
      expect(surface.selectedCell!.lane, 4);
      expect(surface.selectedCell!.row, 15);
      surface.pointer('pointerdown', 960, 540);
      surface.pointer('pointerup', 960, 540);
      expect(surface.selectedCell!.lane, 2);
      expect(surface.selectedCell!.row, -29);
    });

    test('pointercancel and lostpointercapture reset the gesture', () {
      final SceneSurface surface =
          _surface(selectedCell: const SceneCell(4, 15));
      surface.pointer('pointerdown', 500, 500);
      surface.pointer('pointermove', 530, 530);
      final double lane = surface.dragLane;
      final double row = surface.dragRow;
      expect(surface.dragging, isTrue);
      surface.pointer('lostpointercapture', 530, 530);
      expect(surface.dragging, isFalse);
      expect(surface.browsing, isFalse);
      expect(surface.momentumActive, isFalse);
      expect(surface.dragLane, closeTo(lane, 1e-12));
      expect(surface.dragRow, closeTo(row, 1e-12));
      expect(surface.selectedCell!.lane, 4);
      expect(surface.selectedCell!.row, 15);
      surface.pointer('pointerdown', 400, 400);
      expect(surface.dragging, isTrue);
      expect(surface.browsing, isTrue);
      surface.pointer('pointercancel', 400, 400);
      expect(surface.dragging, isFalse);
      expect(surface.browsing, isFalse);
    });

    test('boot mode, the detail transition and the viewer block browse', () {
      final SceneSurface boot = _surface(mode: kFrameModeBoot);
      expect(boot.canBrowse, isFalse);
      expect(boot.canInspect, isFalse);
      boot.pointer('pointerdown', 100, 100);
      expect(boot.dragging, isFalse);

      final SceneSurface fading = _surface(detail: 0.5);
      expect(fading.canBrowse, isFalse);
      fading.pointer('pointerdown', 100, 100);
      expect(fading.dragging, isFalse);

      final SceneSurface viewer =
          _surface(mode: kFrameModeDetail, detail: 1, viewer: true);
      expect(viewer.canInspect, isFalse);
      viewer.pointer('pointerdown', 100, 100);
      expect(viewer.dragging, isFalse);
    });
  });

  group('detail rotation', () {
    test('yaw follows dx * 0.004 and clamps to [-0.8, 0.8]', () {
      final SceneSurface surface =
          _surface(mode: kFrameModeDetail, detail: 1);
      expect(surface.canBrowse, isFalse);
      expect(surface.canInspect, isTrue);
      surface.pointer('pointerdown', 500, 400);
      expect(surface.dragging, isTrue);
      expect(surface.rotating, isTrue);
      expect(surface.browsing, isFalse);
      surface.pointer('pointermove', 700, 400);
      expect(surface.targetRotationYaw, closeTo(0.8, 1e-12));
      surface.pointer('pointermove', 1000, 400);
      expect(surface.targetRotationYaw, closeTo(0.8, 1e-12));
      surface.pointer('pointermove', 0, 400);
      expect(surface.targetRotationYaw, closeTo(-0.8, 1e-12));
      expect(surface.dragLane, 0);
      expect(surface.dragRow, 0);
      surface.advance(1 / 60);
      expect(surface.rotationYaw, lessThan(0));
      for (int frame = 0; frame < 400; frame += 1) {
        surface.advance(1 / 60);
      }
      expect(surface.rotationYaw, closeTo(-0.8, 1e-6));
    });

    test('leaving detail resets the target and returns the yaw to zero', () {
      final SceneSurface surface =
          _surface(mode: kFrameModeDetail, detail: 1);
      surface.pointer('pointerdown', 500, 400);
      surface.pointer('pointermove', 700, 400);
      surface.advance(1 / 60);
      expect(surface.rotationYaw, greaterThan(0));
      surface.pointer('pointerup', 700, 400);
      expect(surface.rotating, isFalse);
      surface.setFrame(_frame());
      expect(surface.targetRotationYaw, 0);
      for (int frame = 0; frame < 400; frame += 1) {
        surface.advance(1 / 60);
      }
      expect(surface.rotationYaw, 0.0);
    });
  });

  group('rotation and resize', () {
    test('rotate cancels the gesture and keeps selection and camera', () {
      final SceneSurface surface =
          _surface(selectedCell: const SceneCell(7, 20));
      surface.pointer('pointerdown', 960, 540);
      surface.pointer('pointermove', 990, 520);
      surface.advance(1 / 60);
      final SceneCamera before = surface.camera;
      final double lane = surface.dragLane;
      surface.rotate(const SceneSize(800, 600));
      expect(surface.size, const SceneSize(800, 600));
      expect(surface.dragging, isFalse);
      expect(surface.browsing, isFalse);
      expect(surface.momentumActive, isFalse);
      expect(surface.selectedCell!.lane, 7);
      expect(surface.selectedCell!.row, 20);
      expect(surface.camera, before);
      expect(surface.dragLane, closeTo(lane, 1e-12));
      surface.pointer('pointerdown', 100, 100);
      expect(surface.dragging, isTrue);
      expect(surface.browsing, isTrue);
      surface.pointer('pointercancel', 100, 100);
      expect(surface.dragging, isFalse);
    });

    test('non-positive or non-finite sizes keep the last valid size', () {
      final SceneSurface surface = _surface();
      surface.resize(const SceneSize(0, 720));
      expect(surface.size, _viewport);
      surface.resize(const SceneSize(1920, double.nan));
      expect(surface.size, _viewport);
      surface.resize(const SceneSize(-10, 720));
      expect(surface.size, _viewport);
      surface.resize(const SceneSize(1280, 720));
      expect(surface.size, const SceneSize(1280, 720));
      surface.rotate(const SceneSize(0, 0));
      expect(surface.size, const SceneSize(1280, 720));
    });
  });

  group('invalid input', () {
    test('an invalid initial size falls back to the frame viewport', () {
      final SceneSurface surface = SceneSurface(
        frame: _frame(),
        size: const SceneSize(0, 0),
      );
      expect(surface.size, _viewport);
    });

    test('non-finite pointer coordinates never move the track', () {
      final SceneSurface surface = _surface();
      surface.pointer('pointerdown', double.nan, 0);
      expect(surface.dragging, isFalse);
      surface.pointer('pointerdown', 10, 10);
      expect(surface.dragging, isTrue);
      surface.pointer('pointermove', double.infinity, 10);
      expect(surface.dragLane, 0);
      surface.pointer('pointermove', 10, double.negativeInfinity);
      expect(surface.dragRow, 0);
      surface.pointer('pointermove', 20, 10);
      expect(surface.dragLane, closeTo(52, 1e-9));
      surface.pointer('pointermove', 20, 10);
      expect(surface.dragLane, closeTo(52, 1e-9));
    });

    test('unknown pointer names and pointerleave are harmless', () {
      final SceneSurface surface = _surface();
      surface.pointer('hover', 100, 100);
      surface.pointer('pointerleave', 100, 100);
      expect(surface.dragging, isFalse);
      expect(surface.dragLane, 0);
    });
  });

  group('dispose', () {
    test('dispose is idempotent and freezes every mutator', () {
      final SceneSurface surface = _surface();
      surface.pointer('pointerdown', 10, 10);
      surface.pointer('pointermove', 30, 10);
      final SceneCamera before = surface.camera;
      final double lane = surface.dragLane;
      surface.dispose();
      expect(surface.isDisposed, isTrue);
      surface.dispose();
      surface.pointer('pointerup', 30, 10);
      surface.pointer('pointerdown', 500, 500);
      expect(surface.dragging, isFalse);
      surface.advance(1);
      expect(surface.camera, before);
      surface.resize(const SceneSize(800, 600));
      expect(surface.size, _viewport);
      surface.setFrame(_frame(mode: kFrameModeDetail, detail: 1));
      expect(surface.frame.mode, kFrameModeArchive);
      surface.rotate(const SceneSize(800, 600));
      expect(surface.size, _viewport);
      expect(surface.dragLane, lane);
    });
  });
}
