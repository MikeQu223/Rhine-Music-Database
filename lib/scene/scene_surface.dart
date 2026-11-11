/// Interactive 3D scene surface: camera pursuit, archive drag browsing and
/// the detail-page yaw gesture.
///
/// Source of truth at commit 3aa6706f91ae7c3c963a3866f27d28e8c63b20fd:
///  * Qt/src/NativeSceneInput.cpp (246 lines) — canBrowse/resetPointer (:6-23),
///    dragProjection (:24-33), navigatePlane/moveArchive (:99-134) and the
///    pointer state machine (:135-200).
///  * Qt/src/NativeSceneCamera.cpp (173 lines) — the exponential camera blend
///    1 - exp(-seconds * 5), the eye/aim/fov pursuit and Matrix::camera
///    semantics (:84-107).
///  * Qt/src/SceneDrag.cpp (125 lines) + SceneDrag.h (59 lines) — archive drag
///    projection, release velocity and the coast/snap momentum.
///  * Qt/src/NativeSceneUpdate.cpp (340 lines) — rotation return (:62-65).
///  * Qt/src/SceneLifetimePolicy.h (57 lines) — returnAngleStep (:31-38).
///  * lib/scene/scene_math.dart (772 lines) — Spring, Mat4.camera,
///    Mat4.perspective, SceneCell and the 5.2 / 0.62 grid pitches.
///
/// The surface is deliberately pure Dart. It does not import Flutter, cannot
/// create a texture or a platform view, and never touches GLB, shaders or the
/// picking BVH. It only owns the numeric state a platform view would drive —
/// camera snapshots, drag bookkeeping, momentum and selection — so the whole
/// interaction can be specified without a device.
///
/// Coordinate contract used by the drag:
///  * pointer coordinates are viewport pixels;
///  * pointer deltas are treated as lane/row deltas (the inverse-projection
///    raycast of NativeSceneInput.cpp:24-33 needs the BVH, which this atom
///    deliberately excludes), then converted with the Qt pitches:
///    lane += dx * 5.2, row -= dy * 0.62 (NativeSceneInput.cpp:129-130);
///  * the accumulated offset is the camera displacement from the frame
///    camera, opposite the content: lane += dx * 5.2 moves the camera by
///    -lane so the grabbed card follows the pointer, and one cell change is
///    one pitch of that offset.
library;

import 'dart:math' as math;

import 'scene_frame.dart';
import 'scene_math.dart';

// ---------------------------------------------------------------------------
// Tuning constants. Every one cites the Qt line it mirrors.
// ---------------------------------------------------------------------------

/// Camera pursuit rate — NativeSceneCamera.cpp:89
/// (blend = 1 - exp(-seconds * 5)).
const double kSurfaceCameraBlendRate = 5.0;

/// Detail yaw per horizontal pointer pixel — NativeSceneInput.cpp:180.
const double kSurfaceYawPerPixel = 0.004;

/// Detail yaw clamp — NativeSceneInput.cpp:180 clamps to [-0.8, 0.8].
const double kSurfaceYawLimit = 0.8;

/// Detail rotation pursuit — NativeSceneUpdate.cpp:64 lerps m_rotation toward
/// m_targetRotation with the shared 1 - exp(-seconds * 2.8) blend.
const double kSurfaceRotationBlendRate = 2.8;

/// Rotation return rate and snap — SceneLifetimePolicy.h:31-38.
const double kSurfaceReturnRate = 7.0;
const double kSurfaceReturnRateReduced = 35.0;
const double kSurfaceReturnSnap = 0.001;

/// A pointer that travels farther than this is a drag, not a tap —
/// NativeSceneInput.cpp:172 (std::hypot(...) > 7) and :31-32.
const double kSurfaceDragSlop = 7.0;

/// Momentum friction and phase thresholds — SceneDrag.cpp:83, :88, :78.
const double kSurfaceMomentumFriction = 2.4;
const double kSurfaceMomentumStart = 0.75;
const double kSurfaceMomentumCoast = 0.6;

/// Momentum snap spring and rest window — SceneDrag.cpp:93-98.
const double kSurfaceSnapRate = 10.0;
const double kSurfaceSnapValue = 0.0001;
const double kSurfaceSnapVelocity = 0.005;

/// One frame step is capped exactly like NativeSceneUpdate.cpp:48
/// (std::min(elapsed, 0.05)) so a long stall cannot explode the spring.
const double kSurfaceMaxStep = 0.05;

/// Nominal spacing of pointer events. The public pointer() signature carries no
/// timestamp, so release velocity is measured over a deterministic 60 Hz event
/// stream instead of wall clock — the same 120 ms / 8 ms windows as
/// SceneDrag.cpp:58, :70.
const double kSurfaceSampleSeconds = 1.0 / 60.0;
const double kSurfaceSampleWindow = 0.12;
const double kSurfaceSampleMinimum = 0.008;

/// The card centre plane used by the tap fallback — kCellBaseY plus the
/// 1.85 m card centre of NativeSceneInput.cpp:25.
const double kSurfaceCardCentreY = kCellBaseY + 1.85;

// ---------------------------------------------------------------------------
// Camera snapshot.
// ---------------------------------------------------------------------------

/// Immutable camera state at one instant.
///
/// The view matrix is always rebuilt from eye/aim with Mat4.camera (:317-337)
/// and then inverted, exactly like NativeSceneCamera.cpp:106
/// (m_view = Matrix::camera(m_eye, m_aim).inverse()). The projection is the
/// frame projection: this atom does not re-derive the archive/detail framing
/// because that is the camera atom's job, not the surface's.
final class SceneCamera {
  const SceneCamera({
    required this.eye,
    required this.aim,
    required this.fov,
    required this.up,
    required this.view,
    required this.projection,
  });

  /// Rebuild the camera that produced a frame.
  ///
  /// A view matrix alone fixes the eye position and the view direction, not the
  /// distance to the aim point (Mat4.camera normalises position - target), so
  /// the reconstructed aim sits one unit in front of the eye. That distance is
  /// not part of the frame contract; the direction is.
  factory SceneCamera.fromFrame(SceneFrame frame) {
    final Mat4 inverse = frame.view.inverse();
    final bool singular = _isZeroMatrix(inverse);
    Vec3 eye = singular
        ? frame.eye
        : Vec3(inverse.values[12], inverse.values[13], inverse.values[14]);
    if (!_isFiniteVec(eye)) {
      eye = Vec3.zero;
    }
    Vec3 back = singular
        ? const Vec3(0, 0, 1)
        : Vec3(inverse.values[8], inverse.values[9], inverse.values[10]);
    Vec3 up = singular
        ? const Vec3(0, 1, 0)
        : Vec3(inverse.values[4], inverse.values[5], inverse.values[6]);
    if (back.length == 0 || !_isFiniteVec(back)) {
      back = const Vec3(0, 0, 1);
    }
    if (up.length == 0 || !_isFiniteVec(up)) {
      up = const Vec3(0, 1, 0);
    }
    back = back.normalized();
    up = up.normalized();
    final double projectionY = frame.projection.values[5];
    final double fov = projectionY.isFinite && projectionY > 0
        ? 2 * math.atan(1 / projectionY) * 180 / math.pi
        : kViewerFov;
    final Vec3 aim = eye - back;
    return SceneCamera(
      eye: eye,
      aim: aim,
      fov: fov,
      up: up,
      view: Mat4.camera(eye, aim).inverse(),
      projection: frame.projection,
    );
  }

  /// World position of the camera.
  final Vec3 eye;

  /// World point the camera looks at.
  final Vec3 aim;

  /// Vertical field of view in degrees — the inverse of
  /// Mat4.perspective's values[5] = 1 / tan(fov / 2).
  final double fov;

  /// Camera up axis (world space).
  final Vec3 up;

  /// World-to-camera matrix.
  final Mat4 view;

  /// Column-major projection carried by the frame.
  final Mat4 projection;

  /// Unit view direction (eye to aim).
  Vec3 get forward => (aim - eye).normalized();

  /// True when every numeric component is finite.
  bool get isFinite =>
      _isFiniteVec(eye) &&
      _isFiniteVec(aim) &&
      _isFiniteVec(up) &&
      fov.isFinite &&
      _isFiniteMatrix(view) &&
      _isFiniteMatrix(projection);

  /// Translate eye and aim together, preserving the orientation.
  SceneCamera translated(Vec3 delta) {
    final Vec3 nextEye = eye + delta;
    final Vec3 nextAim = aim + delta;
    return SceneCamera(
      eye: nextEye,
      aim: nextAim,
      fov: fov,
      up: up,
      view: Mat4.camera(nextEye, nextAim).inverse(),
      projection: projection,
    );
  }

  SceneCamera copyWith({
    Vec3? eye,
    Vec3? aim,
    double? fov,
    Vec3? up,
    Mat4? view,
    Mat4? projection,
  }) {
    final Vec3 nextEye = eye ?? this.eye;
    final Vec3 nextAim = aim ?? this.aim;
    return SceneCamera(
      eye: nextEye,
      aim: nextAim,
      fov: fov ?? this.fov,
      up: up ?? this.up,
      view: view ?? Mat4.camera(nextEye, nextAim).inverse(),
      projection: projection ?? this.projection,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) {
      return true;
    }
    return other is SceneCamera &&
        other.eye == eye &&
        other.aim == aim &&
        other.fov == fov &&
        other.up == up &&
        _sameMatrix(other.view, view) &&
        _sameMatrix(other.projection, projection);
  }

  @override
  int get hashCode => Object.hash(
        eye,
        aim,
        fov,
        up,
        Object.hashAll(view.values),
        Object.hashAll(projection.values),
      );

  @override
  String toString() =>
      'SceneCamera(eye: ' + eye.toString() + ', aim: ' + aim.toString() +
      ', fov: ' + fov.toString() + ')';
}

// ---------------------------------------------------------------------------
// Surface.
// ---------------------------------------------------------------------------

/// The numeric surface behind a 3D scene viewport.
///
/// One instance owns:
///  * the camera snapshot and its pursed target;
///  * the archive drag track (mouse/touch pan) and its momentum;
///  * the detail-page rotation yaw;
///  * the selected cell and the last valid viewport size.
///
/// The class is a state machine, not a widget: it never reads a clock, never
/// allocates a texture and never builds a render tree. advance() is the only
/// place time moves.
final class SceneSurface {
  SceneSurface({
    required SceneFrame frame,
    required SceneSize size,
    double reducedMotion = 0,
    SceneCell? selectedCell,
    SceneCell? originCell,
  })  : _frame = frame,
        _size = _initialSize(size, frame),
        _reducedMotion = _reducedAmount(reducedMotion),
        _selectedCell = selectedCell,
        _originCell = originCell ?? const SceneCell(2, 12),
        _camera = SceneCamera.fromFrame(frame) {
    _baseCamera = _camera;
    _targetCamera = _camera;
  }

  // -- immutable inputs -----------------------------------------------------

  SceneFrame _frame;
  SceneSize _size;
  final double _reducedMotion;
  final SceneCell _originCell;

  // -- camera ---------------------------------------------------------------

  late SceneCamera _baseCamera;
  late SceneCamera _targetCamera;
  SceneCamera _camera;

  // -- browse track (world units along lane / row) --------------------------

  double _laneOffset = 0;
  double _rowOffset = 0;
  double _laneVelocity = 0;
  double _rowVelocity = 0;
  Spring _laneSpring = Spring();
  Spring _rowSpring = Spring();
  bool _momentumActive = false;
  bool _coasting = false;
  double _snapLaneTarget = 0;
  double _snapRowTarget = 0;

  // -- gesture --------------------------------------------------------------

  bool _captured = false;
  bool _browsing = false;
  bool _rotating = false;
  bool _moved = false;
  bool _disposed = false;

  double _downX = 0;
  double _downY = 0;
  double _pointerX = 0;
  double _pointerY = 0;
  double _previousX = 0;

  List<_DragSample> _samples = <_DragSample>[];
  double _sampleTime = 0;

  // -- detail rotation ------------------------------------------------------

  double _yaw = 0;
  double _targetYaw = 0;

  // -- selection ------------------------------------------------------------

  SceneCell? _selectedCell;

  // -- getters --------------------------------------------------------------

  /// The frame currently driving the surface (never mutated).
  SceneFrame get frame => _frame;

  /// Current viewport size; always a valid (finite, positive) size.
  SceneSize get size => _size;

  /// Current camera snapshot.
  SceneCamera get camera => _camera;

  /// The camera the pursuit is aiming at; exposed for diagnostics and tests.
  SceneCamera get targetCamera => _targetCamera;

  /// Selected cell, null until the user taps or a caller supplies one.
  SceneCell? get selectedCell => _selectedCell;

  /// True while a pointer gesture is captured (browse pan or detail yaw).
  bool get dragging => _captured;

  /// True while the captured gesture is an archive browse pan.
  bool get browsing => _browsing;

  /// True while the captured gesture is a detail rotation.
  bool get rotating => _rotating;

  /// True while the release momentum is still coasting or snapping.
  bool get momentumActive => _momentumActive;

  /// True once dispose() ran; every mutator becomes a no-op afterwards.
  bool get isDisposed => _disposed;

  /// 0..1 reduced-motion amount from the constructor.
  double get reducedMotion => _reducedMotion;

  /// True when reduced motion is requested (any non-zero amount).
  bool get isReducedMotion => _reducedMotion > 0;

  /// Accumulated browse lane offset in world units (lane += dx * 5.2).
  double get dragLane => _laneOffset;

  /// Accumulated browse row offset in world units (row -= dy * 0.62).
  double get dragRow => _rowOffset;

  /// Current detail yaw in radians.
  double get rotationYaw => _yaw;

  /// Target detail yaw in radians, clamped to [-0.8, 0.8].
  double get targetRotationYaw => _targetYaw;

  /// NativeSceneInput.cpp:6-8 — the archive is browsable only while it is the
  /// active mode and the detail transition has not started.
  bool get canBrowse =>
      !_frame.viewer && _frame.mode == kFrameModeArchive && _frame.detail < 0.2;

  /// NativeSceneInput.cpp:163 — the detail page can be inspected.
  bool get canInspect => !_frame.viewer && _frame.isDetail;

  // -- frame / size ---------------------------------------------------------

  /// Replace the driving frame.
  ///
  /// While a gesture or momentum is active the base camera is frozen so the
  /// incoming frame cannot teleport the view mid-drag; once idle the frame's
  /// camera becomes the new base and the offsets are applied on top of it.
  void setFrame(SceneFrame frame) {
    if (_disposed) {
      return;
    }
    final bool leftDetail =
        _frame.mode == kFrameModeDetail && frame.mode != kFrameModeDetail;
    _frame = frame;
    if (leftDetail && !_rotating) {
      _targetYaw = 0;
    }
    if (!_captured && !_momentumActive) {
      _baseCamera = SceneCamera.fromFrame(frame);
      _targetCamera = _shiftedCamera(_baseCamera);
    }
  }

  /// Resize the viewport.
  ///
  /// Non-finite or non-positive sizes are ignored and the previous valid size
  /// survives — the early-return of Qt resize handlers.
  void resize(SceneSize size) {
    if (_disposed || !_isValidSize(size)) {
      return;
    }
    _size = size;
  }

  /// Orientation change: adopt the new size, cancel the gesture and momentum,
  /// and keep the selection plus the last valid camera.
  ///
  /// This never throws: an invalid size is ignored exactly like resize().
  void rotate(SceneSize newSize) {
    if (_disposed || !_isValidSize(newSize)) {
      return;
    }
    _size = newSize;
    _resetPointer(stopMomentum: true);
  }

  // -- pointer --------------------------------------------------------------

  /// Feed one pointer event.
  ///
  /// [type] is the Qt event name: pointerdown, pointermove, pointerup,
  /// pointercancel, lostpointercapture or pointerleave. Coordinates are
  /// viewport pixels. Non-finite coordinates are ignored without touching any
  /// state.
  void pointer(String type, double x, double y) {
    if (_disposed || !x.isFinite || !y.isFinite) {
      return;
    }
    switch (type) {
      case 'pointerdown':
        _pointerDown(x, y);
        return;
      case 'pointermove':
        _pointerMove(x, y);
        return;
      case 'pointerup':
        _pointerUp(x, y);
        return;
      case 'pointercancel':
      case 'lostpointercapture':
        _resetPointer(stopMomentum: true);
        return;
      case 'pointerleave':
        // The wall has no hover state in this atom; a captured gesture keeps
        // its capture, exactly like NativeSceneInput.cpp:143-146.
        return;
      default:
        return;
    }
  }

  void _pointerDown(double x, double y) {
    if (_frame.viewer) {
      return;
    }
    final bool browse = canBrowse;
    final bool inspect = canInspect;
    if (!browse && !inspect) {
      return;
    }
    _captured = true;
    _browsing = browse;
    _rotating = inspect && !browse;
    _moved = false;
    _momentumActive = false;
    _coasting = false;
    _laneVelocity = 0;
    _rowVelocity = 0;
    _downX = x;
    _downY = y;
    _pointerX = x;
    _pointerY = y;
    _previousX = x;
    _sampleTime = 0;
    _samples = <_DragSample>[
      _DragSample(_laneOffset, _rowOffset, _sampleTime),
    ];
    _laneSpring = Spring(_laneOffset, 0);
    _rowSpring = Spring(_rowOffset, 0);
  }

  void _pointerMove(double x, double y) {
    if (!_captured) {
      return;
    }
    if (_browsing) {
      if (!canBrowse) {
        _resetPointer(stopMomentum: false);
        return;
      }
      final double dx = x - _pointerX;
      final double dy = y - _pointerY;
      if (dx == 0 && dy == 0) {
        return;
      }
      _laneOffset += dx * kLanePitch;
      _rowOffset -= dy * kRowPitch;
      final double travelledX = x - _downX;
      final double travelledY = y - _downY;
      if (math.sqrt(travelledX * travelledX + travelledY * travelledY) >
          kSurfaceDragSlop) {
        _moved = true;
      }
      _pointerX = x;
      _pointerY = y;
      _sampleTime += kSurfaceSampleSeconds;
      _samples.add(_DragSample(_laneOffset, _rowOffset, _sampleTime));
      while (_samples.length > 1 &&
          _sampleTime - _samples.first.time > kSurfaceSampleWindow) {
        _samples.removeAt(0);
      }
      if (_samples.length > 32) {
        _samples.removeRange(0, _samples.length - 32);
      }
      _targetCamera = _shiftedCamera(_baseCamera);
      return;
    }
    if (_rotating) {
      final double dx = x - _previousX;
      _targetYaw = _clamp(
        _targetYaw + dx * kSurfaceYawPerPixel,
        -kSurfaceYawLimit,
        kSurfaceYawLimit,
      );
      _previousX = x;
      _pointerX = x;
      _pointerY = y;
    }
  }

  void _pointerUp(double x, double y) {
    if (!_captured) {
      return;
    }
    if (_browsing) {
      _pointerMove(x, y);
      if (!_captured) {
        return;
      }
      if (canBrowse) {
        if (_moved) {
          _releaseMomentum();
        } else {
          // A tap is the only explicit "select another cell" gesture; a pan
          // must not steal the selection (navigate keeps it).
          final SceneCell picked =
              _pickCell(x, y) ?? _cellForOffsets(_laneOffset, _rowOffset);
          _selectedCell = picked;
          _laneOffset = -(picked.lane - _originCell.lane) * kLanePitch;
          _rowOffset = -(picked.row - _originCell.row) * kRowPitch;
          _targetCamera = _shiftedCamera(_baseCamera);
        }
      }
    }
    _resetPointer(stopMomentum: false);
  }

  void _releaseMomentum() {
    double laneVelocity = 0;
    double rowVelocity = 0;
    if (_samples.isNotEmpty) {
      final _DragSample first = _samples.first;
      final double span = _sampleTime - first.time;
      if (span >= kSurfaceSampleMinimum) {
        final double scale = 1 / span;
        laneVelocity = (_laneOffset - first.lane) * scale;
        rowVelocity = (_rowOffset - first.row) * scale;
      }
    }
    final double snapLane =
        (_laneOffset / kLanePitch + 0.5).floor() * kLanePitch;
    final double snapRow =
        (_rowOffset / kRowPitch + 0.5).floor() * kRowPitch;
    final bool fast = laneVelocity.abs() / kLanePitch >= kSurfaceMomentumStart ||
        rowVelocity.abs() / kRowPitch >= kSurfaceMomentumStart;
    if (isReducedMotion) {
      _laneOffset = snapLane;
      _rowOffset = snapRow;
      _laneVelocity = 0;
      _rowVelocity = 0;
      _laneSpring = Spring(_laneOffset, 0);
      _rowSpring = Spring(_rowOffset, 0);
      _momentumActive = false;
      _coasting = false;
      _targetCamera = _shiftedCamera(_baseCamera);
      return;
    }
    _laneVelocity = laneVelocity;
    _rowVelocity = rowVelocity;
    _laneSpring = Spring(_laneOffset, laneVelocity);
    _rowSpring = Spring(_rowOffset, rowVelocity);
    _snapLaneTarget = snapLane;
    _snapRowTarget = snapRow;
    _coasting = fast;
    _momentumActive = true;
    _targetCamera = _shiftedCamera(_baseCamera);
  }

  void _resetPointer({required bool stopMomentum}) {
    _captured = false;
    _browsing = false;
    _rotating = false;
    _moved = false;
    _samples = <_DragSample>[];
    if (stopMomentum) {
      _momentumActive = false;
      _coasting = false;
      _laneVelocity = 0;
      _rowVelocity = 0;
    }
  }

  // -- time -----------------------------------------------------------------

  /// Advance the camera, momentum and rotation by one fixed step.
  ///
  /// The step is clamped to kSurfaceMaxStep (NativeSceneUpdate.cpp:48). A zero,
  /// negative or non-finite step is ignored. The camera pursuit is monotone
  /// toward a constant target and cannot produce NaN or infinity because every
  /// input is finite and every blend factor stays in [0, 1].
  void advance(double seconds) {
    if (_disposed || !seconds.isFinite || seconds <= 0) {
      return;
    }
    final double step = seconds > kSurfaceMaxStep ? kSurfaceMaxStep : seconds;
    _advanceMomentum(step);
    _advanceCamera(step);
    _advanceRotation(step);
  }

  void _advanceMomentum(double step) {
    if (!_momentumActive) {
      return;
    }
    if (_coasting) {
      final double decay = math.exp(-kSurfaceMomentumFriction * step);
      _laneOffset +=
          _laneVelocity * (1 - decay) / kSurfaceMomentumFriction;
      _rowOffset += _rowVelocity * (1 - decay) / kSurfaceMomentumFriction;
      _laneVelocity *= decay;
      _rowVelocity *= decay;
      final double laneCells = _laneVelocity.abs() / kLanePitch;
      final double rowCells = _rowVelocity.abs() / kRowPitch;
      if (laneCells < kSurfaceMomentumCoast &&
          rowCells < kSurfaceMomentumCoast) {
        _coasting = false;
        _laneSpring = Spring(_laneOffset, _laneVelocity);
        _rowSpring = Spring(_rowOffset, _rowVelocity);
        _snapLaneTarget =
            ((_laneOffset + _laneVelocity / kSurfaceMomentumFriction) /
                        kLanePitch +
                    0.5)
                .floor() *
            kLanePitch;
        _snapRowTarget =
            ((_rowOffset + _rowVelocity / kSurfaceMomentumFriction) /
                        kRowPitch +
                    0.5)
                .floor() *
            kRowPitch;
      }
    } else {
      _laneSpring.damp(_snapLaneTarget, kSurfaceSnapRate, step);
      _rowSpring.damp(_snapRowTarget, kSurfaceSnapRate, step);
      _laneOffset = _laneSpring.value;
      _rowOffset = _rowSpring.value;
      final bool laneSettled =
          (_laneOffset - _snapLaneTarget).abs() < kSurfaceSnapValue &&
              _laneSpring.velocity.abs() < kSurfaceSnapVelocity;
      final bool rowSettled =
          (_rowOffset - _snapRowTarget).abs() < kSurfaceSnapValue &&
              _rowSpring.velocity.abs() < kSurfaceSnapVelocity;
      if (laneSettled && rowSettled) {
        _laneOffset = _snapLaneTarget;
        _rowOffset = _snapRowTarget;
        _laneSpring = Spring(_laneOffset, 0);
        _rowSpring = Spring(_rowOffset, 0);
        _momentumActive = false;
        _coasting = false;
      }
    }
    _targetCamera = _shiftedCamera(_baseCamera);
  }

  void _advanceCamera(double step) {
    final double blend = isReducedMotion
        ? 1.0
        : 1.0 - math.exp(-kSurfaceCameraBlendRate * step);
    final Vec3 eye = _camera.eye.lerp(_targetCamera.eye, blend);
    final Vec3 aim = _camera.aim.lerp(_targetCamera.aim, blend);
    final double fov = _camera.fov + (_targetCamera.fov - _camera.fov) * blend;
    final SceneCamera next = SceneCamera(
      eye: eye,
      aim: aim,
      fov: fov,
      up: _targetCamera.up,
      view: Mat4.camera(eye, aim).inverse(),
      projection: _targetCamera.projection,
    );
    if (!next.isFinite) {
      return;
    }
    _camera = next;
  }

  void _advanceRotation(double step) {
    if (isReducedMotion) {
      if (_frame.mode == kFrameModeDetail) {
        _yaw = _targetYaw;
      } else if (!_rotating) {
        _targetYaw = 0;
        _yaw = 0;
      }
      return;
    }
    if (_frame.mode == kFrameModeDetail) {
      final double blend = 1 - math.exp(-kSurfaceRotationBlendRate * step);
      _yaw += (_targetYaw - _yaw) * blend;
      return;
    }
    if (!_rotating) {
      _targetYaw = 0;
      _yaw = _returnStep(_yaw, step, false);
    }
  }

  // -- selection ------------------------------------------------------------

  /// Pick the cell under a viewport point.
  ///
  /// This is a ray/plane intersection with the card-centre plane, not the Qt
  /// BVH picker (NativeSceneInput.cpp:36-97 needs the native meshes). It is the
  /// deterministic nearest-cell fallback the atom asks for: project the pointer,
  /// intersect y = card centre, then round lane/row with the 5.2 / 0.62 grid.
  SceneCell? _pickCell(double x, double y) {
    if (_size.isEmpty) {
      return null;
    }
    final double ndcX = x / _size.width * 2 - 1;
    final double ndcY = -y / _size.height * 2 + 1;
    final Mat4 view = Mat4.camera(_camera.eye, _camera.aim).inverse();
    final Mat4 inverse = (_frame.projection * view).inverse();
    if (_isZeroMatrix(inverse)) {
      return null;
    }
    final Vec3 target = inverse.point(Vec3(ndcX, ndcY, 0.5));
    final Vec3 direction = (target - _camera.eye).normalized();
    if (direction.length == 0 || !_isFiniteVec(direction)) {
      return null;
    }
    if (direction.y.abs() < 1e-9) {
      return null;
    }
    final double t = (kSurfaceCardCentreY - _camera.eye.y) / direction.y;
    if (!t.isFinite || t <= 0) {
      return null;
    }
    final Vec3 hit = _camera.eye + direction * t;
    if (!_isFiniteVec(hit)) {
      return null;
    }
    final int lane = (hit.x / kLanePitch + 2 + 0.5).floor();
    final int row = (hit.z / kRowPitch + kRowCentre + 0.5).floor();
    return SceneCell(lane, row);
  }

  SceneCell _cellForOffsets(double laneOffset, double rowOffset) => SceneCell(
        _originCell.lane - (laneOffset / kLanePitch + 0.5).floor(),
        _originCell.row - (rowOffset / kRowPitch + 0.5).floor(),
      );

  // -- camera helpers -------------------------------------------------------

  /// The frame camera translated opposite to the accumulated track, so the
  /// grabbed content follows the pointer.
  SceneCamera _shiftedCamera(SceneCamera base) {
    final Vec3 delta = Vec3(-_laneOffset, 0, -_rowOffset);
    return base.translated(delta);
  }

  double _returnStep(double angle, double seconds, bool reduced) {
    if (seconds <= 0) {
      return angle;
    }
    final double next = angle *
        math.exp(-seconds * (reduced ? kSurfaceReturnRateReduced : kSurfaceReturnRate));
    return next.abs() <= kSurfaceReturnSnap ? 0 : next;
  }

  // -- lifecycle ------------------------------------------------------------

  /// Release the surface. Idempotent; every mutator becomes a no-op afterwards.
  void dispose() {
    if (_disposed) {
      return;
    }
    _disposed = true;
    _resetPointer(stopMomentum: true);
    _samples = <_DragSample>[];
  }

  @override
  String toString() => 'SceneSurface(mode: ' +
      _frame.mode +
      ', selectedCell: ' +
      _selectedCell.toString() +
      ', offset: (' +
      _laneOffset.toString() +
      ', ' +
      _rowOffset.toString() +
      '), dragging: ' +
      _captured.toString() +
      ')';
}

// ---------------------------------------------------------------------------
// Small value / helper types.
// ---------------------------------------------------------------------------

final class _DragSample {
  const _DragSample(this.lane, this.row, this.time);

  final double lane;
  final double row;
  final double time;
}

double _clamp(double value, double minimum, double maximum) =>
    value < minimum ? minimum : (value > maximum ? maximum : value);

double _reducedAmount(double value) {
  if (!value.isFinite) {
    return 0;
  }
  return _clamp(value, 0, 1);
}

bool _isValidSize(SceneSize size) =>
    size.width.isFinite &&
    size.height.isFinite &&
    size.width > 0 &&
    size.height > 0;

SceneSize _initialSize(SceneSize requested, SceneFrame frame) {
  if (_isValidSize(requested)) {
    return requested;
  }
  if (_isValidSize(frame.viewport)) {
    return frame.viewport;
  }
  return SceneSize.stageFallback;
}

bool _isFiniteVec(Vec3 value) =>
    value.x.isFinite && value.y.isFinite && value.z.isFinite;

bool _isFiniteMatrix(Mat4 matrix) {
  for (int index = 0; index < 16; ++index) {
    if (!matrix.values[index].isFinite) {
      return false;
    }
  }
  return true;
}

bool _isZeroMatrix(Mat4 matrix) {
  for (int index = 0; index < 16; ++index) {
    if (matrix.values[index] != 0) {
      return false;
    }
  }
  return true;
}

bool _sameMatrix(Mat4 first, Mat4 second) {
  for (int index = 0; index < 16; ++index) {
    if (first.values[index] != second.values[index]) {
      return false;
    }
  }
  return true;
}
