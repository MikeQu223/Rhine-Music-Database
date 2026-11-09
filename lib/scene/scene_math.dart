/// Faithful Dart port of the Qt scene math used by the 3D wall and the 3D
/// viewer.
///
/// Source of truth: `Qt/src/SceneMath.h` (45 lines) and `Qt/src/SceneMath.cpp`
/// (219 lines) at commit 8ed3067b0812eb2612f7841ec127a6e8ca93231b.
///
/// Conventions copied verbatim from the C++:
///  * `Mat4.values` is column-major, `index == column * 4 + row`
///    (SceneMath.h:22 "按 OpenGL 列主序存储双精度矩阵，只在提交 GPU 时压为 Float32").
///  * `Vec3.normalized()` of a zero-length vector returns the vector unchanged
///    (SceneMath.cpp:26-29 multiplies by 1 when `length() == 0`).
///  * `Mat4.inverse()` returns an all-zero matrix for singular input
///    (SceneMath.cpp:126-130) instead of throwing.
///  * `Mat4.point()` divides by w with no `w == 0` guard (SceneMath.cpp:158-164).
///  * `Frustum` plane order is left(-x), right(+x), bottom(-y), top(+y),
///    near(-z), far(+z) (SceneMath.cpp:184-198).
library;

import 'dart:math' as math;
import 'dart:typed_data';

// ---------------------------------------------------------------------------
// Projection constants. Every value cites the Qt line it was taken from.
// ---------------------------------------------------------------------------

/// Scene (3D wall) main projection clip planes — NativeSceneCamera.cpp:98.
const double kSceneNear = 5.0;
const double kSceneFar = 300.0;

/// Cull projection fog window — NativeSceneCamera.cpp:115:
/// `std::min(300.0, std::max(6.0, m_fogFar + 8))`.
const double kCullMinFar = 6.0;
const double kCullFogMargin = 8.0;

/// NDC projection-centre offsets — NativeSceneCamera.cpp:102-103.
const double kArchiveOffsetX = 0.16;
const double kArchiveOffsetY = 0.20;

/// Detail window of the archive offset — NativeSceneCamera.cpp:100.
const double kArchiveDetailStart = 0.25;
const double kArchiveDetailSpan = 0.55;

/// Cull/pick projections widen the frustum by this factor
/// (NativeSceneCamera.cpp:116-117 divides values[0] and values[5] by 1.18).
const double kCullExpansion = 1.18;

/// Portrait threshold shared by the wall and the viewer
/// (NativeSceneCamera.cpp:56, NativeViewer.cpp:288).
const double kPortraitAspect = 1.05;

/// Compact-wall breakpoint — NativeSceneCamera.cpp:57.
const double kCompactWidth = 1100.0;
const double kDefaultAnchorX = 550.0 / 1920;
const double kDefaultAnchorY = 560.0 / 1080;
const double kPortraitAnchorY = 0.27;
const double kPortraitAnchorYBias = 34.0;
const double kCompactAnchorX = 0.27;
const double kCompactAnchorY = 0.49;

/// Viewer (NativeViewer) projection — NativeViewer.cpp:287.
const double kViewerFov = 34.0;
const double kViewerNear = 0.3;
const double kViewerFar = 120.0;
/// NativeViewer.cpp:289 — `std::min(1.15, aspect / 0.85) / (1 + 0.08 * spread)`.
const double kViewerZoomCap = 1.15;
const double kViewerZoomAspectBase = 0.85;
const double kViewerSpreadZoom = 0.08;

/// Wall geometry — NativeScene.cpp:77 and NativeSceneCamera.cpp:159-167.
const double kLanePitch = 5.2;
const double kRowPitch = 0.62;
const double kRowCentre = 15.5;
const double kCellBaseY = -4.6;
const double kCellHalfWidth = 2.8;
const double kCellHalfDepth = 1.2;
const double kCellHalfHeight = 6.5;
const double kCardMinX = -2.8;
const double kCardMinY = -0.3;
const double kCardMinZ = -1.2;
const double kCardMaxX = 2.8;
const double kCardMaxY = 4.1;
const double kCardMaxZ = 1.2;

/// Row index of the first record inside a lane — NativeScene.cpp:67.
const int kLaneRowOrigin = 12;

// ---------------------------------------------------------------------------
// Scalar helpers — SceneMotion.cpp:9-14, 42-49.
// ---------------------------------------------------------------------------

/// `clamp(v, 0, 1)` — SceneMotion.cpp:9-11.
double clamp01(double value) => value < 0 ? 0 : (value > 1 ? 1 : value);

/// The clamped quintic smoothstep used everywhere as a progress curve —
/// SceneMotion.cpp:42-45: `v * v * v * (10 + v * (-15 + 6 * v))`.
double smoothStep5(double value) {
  final double v = clamp01(value);
  return v * v * v * (10 + v * (-15 + 6 * v));
}

/// The clamped cubic smoothstep — SceneMotion.cpp:46-49: `v * v * (3 - 2 * v)`.
double easeStep(double value) {
  final double v = clamp01(value);
  return v * v * (3 - 2 * v);
}

/// `exp(-0.5 * (value / width)^2)` — SceneMotion.cpp:13-14.
double bellCurve(double value, double width) => math.exp(-0.5 * (value / width) * (value / width));

/// Linear interpolation — SceneMath.cpp:30-32 / NativeSceneCamera.cpp lerp.
double lerpDouble(double from, double to, double amount) => from + (to - from) * amount;

// ---------------------------------------------------------------------------
// Motion primitives — SceneMotion.h:20-32, SceneMotion.cpp:52-122.
// ---------------------------------------------------------------------------

/// One control point of a Qt `SceneMotion::Curve` (QVector<QPair<double,double>>).
class CurveKey {
  const CurveKey(this.time, this.value);

  final double time;
  final double value;
}

/// Monotone cubic Hermite interpolation — SceneMotion.cpp:52-95.
///
/// Interior tangents use the Qt weighted harmonic mean
/// `(w0 + w1) / (w0 / a + w1 / b)` with `w0 = 2 * right + left`,
/// `w1 = right + 2 * left`; a tangent is zero when the neighbouring slopes
/// have opposite signs or when an end is stationary.
double trackCurve(List<CurveKey> keys, double time, {bool stationaryEnds = false}) {
  if (keys.isEmpty) {
    return 0;
  }
  if (time <= keys.first.time) {
    return keys.first.value;
  }
  if (time >= keys.last.time) {
    return keys.last.value;
  }
  final int last = keys.length - 1;
  double slope(int index) =>
      (keys[index + 1].value - keys[index].value) / (keys[index + 1].time - keys[index].time);
  double tangent(int index) {
    if (index == 0 || index == last) {
      return stationaryEnds ? 0 : slope(index == 0 ? 0 : last - 1);
    }
    final double a = slope(index - 1);
    final double b = slope(index);
    if (a * b <= 0) {
      return 0;
    }
    final double left = keys[index].time - keys[index - 1].time;
    final double right = keys[index + 1].time - keys[index].time;
    final double w0 = 2 * right + left;
    final double w1 = right + 2 * left;
    return (w0 + w1) / (w0 / a + w1 / b);
  }

  int index = 1;
  while (index < keys.length && keys[index].time <= time) {
    ++index;
  }
  final int lower = index - 1;
  final double span = keys[lower + 1].time - keys[lower].time;
  final double amount = span == 0 ? 0 : (time - keys[lower].time) / span;
  final double square = amount * amount;
  final double cube = square * amount;
  return (2 * cube - 3 * square + 1) * keys[lower].value +
      (cube - 2 * square + amount) * span * tangent(lower) +
      (-2 * cube + 3 * square) * keys[lower + 1].value +
      (cube - square) * span * tangent(lower + 1);
}

/// Critically damped spring — SceneMotion.h:27-32, SceneMotion.cpp:113-119.
class Spring {
  Spring([this.value = 0, this.velocity = 0]);

  double value;
  double velocity;

  void damp(double target, double rate, double seconds) {
    final double delta = value - target;
    final double impulse = velocity + rate * delta;
    final double decay = math.exp(-rate * seconds);
    value = target + (delta + impulse * seconds) * decay;
    velocity = (velocity - rate * impulse * seconds) * decay;
  }
}

// ---------------------------------------------------------------------------
// Vector / matrix / frustum — SceneMath.h:7-44, SceneMath.cpp:8-217.
// ---------------------------------------------------------------------------

/// Qt `SceneMath::Vector`.
class Vec3 {
  const Vec3(this.x, this.y, this.z);

  static const Vec3 zero = Vec3(0, 0, 0);

  final double x;
  final double y;
  final double z;

  Vec3 operator +(Vec3 other) => Vec3(x + other.x, y + other.y, z + other.z);

  Vec3 operator -(Vec3 other) => Vec3(x - other.x, y - other.y, z - other.z);

  Vec3 operator *(double scale) => Vec3(x * scale, y * scale, z * scale);

  double dot(Vec3 other) => x * other.x + y * other.y + z * other.z;

  Vec3 cross(Vec3 other) =>
      Vec3(y * other.z - z * other.y, z * other.x - x * other.z, x * other.y - y * other.x);

  double get length => math.sqrt(x * x + y * y + z * z);

  /// SceneMath.cpp:26-29 — a zero-length vector is returned unchanged.
  Vec3 normalized() {
    final double size = length;
    return this * (size == 0 ? 1 : 1 / size);
  }

  Vec3 lerp(Vec3 other, double amount) =>
      Vec3(x + (other.x - x) * amount, y + (other.y - y) * amount, z + (other.z - z) * amount);

  List<double> toJson() => <double>[x, y, z];

  @override
  bool operator ==(Object other) =>
      other is Vec3 && other.x == x && other.y == y && other.z == z;

  @override
  int get hashCode => Object.hash(x, y, z);

  @override
  String toString() => 'Vec3($x, $y, $z)';
}

/// Qt `SceneMath::Matrix` — 16 doubles in column-major order.
class Mat4 {
  Mat4([List<double>? values]) : values = Float64List.fromList(values ?? _identityOrder);

  static const List<double> _identityOrder = <double>[
    1, 0, 0, 0, //
    0, 1, 0, 0, //
    0, 0, 1, 0, //
    0, 0, 0, 1,
  ];

  /// Column-major storage: `values[column * 4 + row]`.
  final Float64List values;

  double operator [](int index) => values[index];

  void operator []=(int index, double value) {
    values[index] = value;
  }

  Mat4 clone() => Mat4(values.toList());

  /// SceneMath.cpp:37-63.
  static Mat4 compose(Vec3 position, Vec3 rotation, [Vec3 scale = const Vec3(1, 1, 1)]) {
    final double c1 = math.cos(rotation.x / 2);
    final double c2 = math.cos(rotation.y / 2);
    final double c3 = math.cos(rotation.z / 2);
    final double s1 = math.sin(rotation.x / 2);
    final double s2 = math.sin(rotation.y / 2);
    final double s3 = math.sin(rotation.z / 2);
    final double x = s1 * c2 * c3 + c1 * s2 * s3;
    final double y = c1 * s2 * c3 - s1 * c2 * s3;
    final double z = c1 * c2 * s3 + s1 * s2 * c3;
    final double w = c1 * c2 * c3 - s1 * s2 * s3;
    final double x2 = x + x;
    final double y2 = y + y;
    final double z2 = z + z;
    final double xx = x * x2;
    final double xy = x * y2;
    final double xz = x * z2;
    final double yy = y * y2;
    final double yz = y * z2;
    final double zz = z * z2;
    final double wx = w * x2;
    final double wy = w * y2;
    final double wz = w * z2;
    return Mat4(<double>[
      (1 - (yy + zz)) * scale.x, (xy + wz) * scale.x, (xz - wy) * scale.x, 0, //
      (xy - wz) * scale.y, (1 - (xx + zz)) * scale.y, (yz + wx) * scale.y, 0, //
      (xz + wy) * scale.z, (yz - wx) * scale.z, (1 - (xx + yy)) * scale.z, 0, //
      position.x, position.y, position.z, 1,
    ]);
  }

  /// SceneMath.cpp:64-78 — `fovDegrees` is in degrees, the frustum is symmetric.
  static Mat4 perspective(double fovDegrees, double aspect, double near, double far) {
    final double top = near * math.tan(math.pi / 180 * 0.5 * fovDegrees);
    final double height = 2 * top;
    final double width = aspect * height;
    final double left = -0.5 * width;
    final double right = left + width;
    final double bottom = top - height;
    final double x = 2 * near / (right - left);
    final double y = 2 * near / (top - bottom);
    final double a = (right + left) / (right - left);
    final double b = (top + bottom) / (top - bottom);
    final double c = -(far + near) / (far - near);
    final double d = -2 * far * near / (far - near);
    return Mat4(<double>[
      x, 0, 0, 0, //
      0, y, 0, 0, //
      a, b, c, -1, //
      0, 0, d, 0,
    ]);
  }

  /// SceneMath.cpp:79-95 — columns are the right/up/back basis and the position.
  static Mat4 camera(Vec3 position, Vec3 target) {
    Vec3 z = position - target;
    if (z.length == 0) {
      z = Vec3(z.x, z.y, 1);
    }
    z = z.normalized();
    const Vec3 up = Vec3(0, 1, 0);
    Vec3 x = up.cross(z);
    if (x.length == 0) {
      z = Vec3(z.x, z.y, z.z + 0.0001).normalized();
      x = up.cross(z);
    }
    x = x.normalized();
    final Vec3 y = z.cross(x);
    return Mat4(<double>[
      x.x, x.y, x.z, 0, //
      y.x, y.y, y.z, 0, //
      z.x, z.y, z.z, 0, //
      position.x, position.y, position.z, 1,
    ]);
  }

  /// SceneMath.cpp:96-108 — `result.values[column * 4 + row] = sum_k ...`.
  Mat4 operator *(Mat4 other) {
    final Mat4 result = Mat4();
    for (int column = 0; column < 4; ++column) {
      for (int row = 0; row < 4; ++row) {
        double value = 0;
        for (int k = 0; k < 4; ++k) {
          value += values[k * 4 + row] * other.values[column * 4 + k];
        }
        result.values[column * 4 + row] = value;
      }
    }
    return result;
  }

  /// SceneMath.cpp:110-157 — Gauss-Jordan with partial pivoting; a singular
  /// input yields the all-zero matrix.
  Mat4 inverse() {
    final List<List<double>> rows =
        List<List<double>>.generate(4, (_) => List<double>.filled(8, 0));
    for (int row = 0; row < 4; ++row) {
      for (int column = 0; column < 4; ++column) {
        rows[row][column] = values[column * 4 + row];
      }
      rows[row][row + 4] = 1;
    }
    for (int column = 0; column < 4; ++column) {
      int pivot = column;
      for (int row = column + 1; row < 4; ++row) {
        if (rows[row][column].abs() > rows[pivot][column].abs()) {
          pivot = row;
        }
      }
      if (rows[pivot][column] == 0) {
        return Mat4(List<double>.filled(16, 0));
      }
      if (pivot != column) {
        for (int index = 0; index < 8; ++index) {
          final double swap = rows[pivot][index];
          rows[pivot][index] = rows[column][index];
          rows[column][index] = swap;
        }
      }
      final double divisor = rows[column][column];
      for (int index = 0; index < 8; ++index) {
        rows[column][index] /= divisor;
      }
      for (int row = 0; row < 4; ++row) {
        if (row == column) {
          continue;
        }
        final double factor = rows[row][column];
        for (int index = 0; index < 8; ++index) {
          rows[row][index] -= factor * rows[column][index];
        }
      }
    }
    final Mat4 result = Mat4();
    for (int row = 0; row < 4; ++row) {
      for (int column = 0; column < 4; ++column) {
        result.values[column * 4 + row] = rows[row][column + 4];
      }
    }
    return result;
  }

  /// SceneMath.cpp:158-164 — perspective divide with no w == 0 guard.
  Vec3 point(Vec3 point) {
    final double w = 1 / (values[3] * point.x + values[7] * point.y + values[11] * point.z + values[15]);
    return Vec3(
      (values[0] * point.x + values[4] * point.y + values[8] * point.z + values[12]) * w,
      (values[1] * point.x + values[5] * point.y + values[9] * point.z + values[13]) * w,
      (values[2] * point.x + values[6] * point.y + values[10] * point.z + values[14]) * w,
    );
  }

  /// SceneMath.cpp:165-171 — affine part only, then normalized.
  Vec3 direction(Vec3 vector) => Vec3(
        values[0] * vector.x + values[4] * vector.y + values[8] * vector.z,
        values[1] * vector.x + values[5] * vector.y + values[9] * vector.z,
        values[2] * vector.x + values[6] * vector.y + values[10] * vector.z,
      ).normalized();

  /// SceneMath.cpp:172-178 — the 16 values in stored (column-major) order.
  List<double> toJson() => List<double>.from(values);

  /// SceneMath.cpp:179-183 — 64 bytes of Float32, the GPU submit layout.
  Uint8List toBytes() {
    final Float32List narrowed = Float32List(16);
    for (int index = 0; index < 16; ++index) {
      narrowed[index] = values[index];
    }
    return narrowed.buffer.asUint8List(narrowed.offsetInBytes, narrowed.lengthInBytes);
  }

  @override
  String toString() => 'Mat4(${values.toList()})';
}

/// Qt `SceneMath::Frustum` — six normalized planes in
/// left, right, bottom, top, near, far order.
class Frustum {
  Frustum(Mat4 projectionView) : planes = _extractPlanes(projectionView);

  /// Each plane is `[a, b, c, d]` with `a*x + b*y + c*z + d` the signed distance.
  final List<Float64List> planes;

  static List<Float64List> _extractPlanes(Mat4 matrix) {
    final Float64List m = matrix.values;
    final List<Float64List> planes = <Float64List>[];
    for (int index = 0; index < 6; ++index) {
      final int component = index ~/ 2;
      final double sign = index % 2 == 0 ? -1 : 1;
      final Float64List plane = Float64List(4);
      for (int column = 0; column < 4; ++column) {
        plane[column] = m[column * 4 + 3] + sign * m[column * 4 + component];
      }
      final double length =
          math.sqrt(plane[0] * plane[0] + plane[1] * plane[1] + plane[2] * plane[2]);
      for (int slot = 0; slot < 4; ++slot) {
        plane[slot] /= length;
      }
      planes.add(plane);
    }
    return planes;
  }

  /// SceneMath.cpp:199-209 — the positive-most corner of the box is tested
  /// against every plane.
  bool intersects(Vec3 minimum, Vec3 maximum) {
    for (final Float64List plane in planes) {
      final double x = plane[0] > 0 ? maximum.x : minimum.x;
      final double y = plane[1] > 0 ? maximum.y : minimum.y;
      final double z = plane[2] > 0 ? maximum.z : minimum.z;
      if (plane[0] * x + plane[1] * y + plane[2] * z + plane[3] < 0) {
        return false;
      }
    }
    return true;
  }

  /// SceneMath.cpp:210-217.
  bool intersectsSphere(Vec3 center, double radius) {
    for (final Float64List plane in planes) {
      if (plane[0] * center.x + plane[1] * center.y + plane[2] * center.z + plane[3] < -radius) {
        return false;
      }
    }
    return true;
  }
}

// ---------------------------------------------------------------------------
// Wall geometry — NativeScene.cpp:63-78, NativeSceneCamera.cpp:109-171.
// ---------------------------------------------------------------------------

/// A lane/row address on the 3D wall — Qt `SceneMath::Cell` / NativeScene::Cell.
class SceneCell {
  const SceneCell(this.lane, this.row);

  final int lane;
  final int row;

  /// SceneMotion.cpp:120-122 — `lane:row`, the texture/track cache key.
  String get key => '$lane:$row';

  @override
  bool operator ==(Object other) =>
      other is SceneCell && other.lane == lane && other.row == row;

  @override
  int get hashCode => Object.hash(lane, row);

  @override
  String toString() => 'SceneCell($lane, $row)';
}

/// NativeScene.cpp:77 — the canonical cell origin without track offsets.
Vec3 cellPosition(SceneCell cell) => Vec3(
      (cell.lane - 2) * kLanePitch,
      kCellBaseY,
      (cell.row - kRowCentre) * kRowPitch,
    );

/// NativeSceneCamera.cpp:165-166 — the tracked world position; `trackX` is
/// subtracted and `trackZ` added, exactly as in Qt.
Vec3 trackedCellPosition(SceneCell cell, {required double trackX, required double trackZ}) => Vec3(
      (cell.lane - 2) * kLanePitch - trackX,
      kCellBaseY,
      (cell.row - kRowCentre) * kRowPitch + trackZ,
    );

/// NativeScene.cpp:63-71 — record `indexInLane` sits on row `12 + indexInLane`.
SceneCell fileLocation({required int lane, required int indexInLane}) =>
    SceneCell(lane, kLaneRowOrigin + indexInLane);

/// NativeSceneCamera.cpp:110 — the card cull box relative to the card position.
bool intersectsCard(Frustum frustum, Vec3 position) => frustum.intersects(
      position + const Vec3(kCardMinX, kCardMinY, kCardMinZ),
      position + const Vec3(kCardMaxX, kCardMaxY, kCardMaxZ),
    );

/// The lane/row window produced by the Qt reverse solve.
class CellIndexRange {
  const CellIndexRange({
    required this.minLane,
    required this.maxLane,
    required this.minRow,
    required this.maxRow,
  });

  final int minLane;
  final int maxLane;
  final int minRow;
  final int maxRow;
}

/// NativeSceneCamera.cpp:159-162 — the cull AABB expanded back into indices.
///
/// Qt deliberately does **not** clamp lanes or rows here; out-of-range cells are
/// folded back by the caller (NativeScene.cpp:73 `wrap(cell.lane, 5)`).
CellIndexRange cellIndexRange({
  required Vec3 minimum,
  required Vec3 maximum,
  required double trackX,
  required double trackZ,
}) =>
    CellIndexRange(
      minLane: ((minimum.x - kCellHalfWidth + trackX) / kLanePitch + 2).floor() - 1,
      maxLane: ((maximum.x + kCellHalfWidth + trackX) / kLanePitch + 2).ceil() + 1,
      minRow: ((minimum.z - 0.6 - trackZ) / kRowPitch + kRowCentre).floor() - 2,
      maxRow: ((maximum.z + 0.6 - trackZ) / kRowPitch + kRowCentre).ceil() + 2,
    );

/// NativeSceneCamera.cpp:113-173 — the culled cell list.
///
/// `projection` must already be the cull projection (see [cullProjection]) and
/// `view` the inverse camera matrix. The Qt y window `[-6.5, 6.5]` and the
/// 12-edge clipping loop are reproduced so the visible set matches bit for bit.
List<SceneCell> visibleCells({
  required Mat4 projection,
  required Mat4 view,
  required double trackX,
  required double trackZ,
}) {
  final Mat4 matrix = projection * view;
  final Frustum frustum = Frustum(matrix);
  final Mat4 inverse = matrix.inverse();

  final List<Vec3> vertices = <Vec3>[];
  for (int index = 0; index < 8; ++index) {
    vertices.add(inverse.point(Vec3(
      (index & 1) != 0 ? 1.0 : -1.0,
      (index & 2) != 0 ? 1.0 : -1.0,
      (index & 4) != 0 ? 1.0 : -1.0,
    )));
  }

  double minimumX = 1e100;
  double minimumY = 1e100;
  double minimumZ = 1e100;
  double maximumX = -1e100;
  double maximumY = -1e100;
  double maximumZ = -1e100;
  void include(Vec3 point) {
    minimumX = math.min(minimumX, point.x);
    minimumY = math.min(minimumY, point.y);
    minimumZ = math.min(minimumZ, point.z);
    maximumX = math.max(maximumX, point.x);
    maximumY = math.max(maximumY, point.y);
    maximumZ = math.max(maximumZ, point.z);
  }

  for (final Vec3 vertex in vertices) {
    if (vertex.y >= -kCellHalfHeight && vertex.y <= kCellHalfHeight) {
      include(vertex);
    }
  }

  const List<List<int>> edges = <List<int>>[
    <int>[0, 1], <int>[0, 2], <int>[0, 4], <int>[1, 3], <int>[1, 5], <int>[2, 3], //
    <int>[2, 6], <int>[3, 7], <int>[4, 5], <int>[4, 6], <int>[5, 7], <int>[6, 7],
  ];
  for (final List<int> edge in edges) {
    final Vec3 start = vertices[edge[0]];
    final Vec3 end = vertices[edge[1]];
    final double dy = end.y - start.y;
    if (dy.abs() < 1e-9) {
      continue;
    }
    for (final double height in <double>[-kCellHalfHeight, kCellHalfHeight]) {
      final double amount = (height - start.y) / dy;
      if (amount >= 0 && amount <= 1) {
        include(start.lerp(end, amount));
      }
    }
  }

  final List<SceneCell> result = <SceneCell>[];
  if (maximumX < minimumX) {
    return result;
  }
  final CellIndexRange range = cellIndexRange(
    minimum: Vec3(minimumX, minimumY, minimumZ),
    maximum: Vec3(maximumX, maximumY, maximumZ),
    trackX: trackX,
    trackZ: trackZ,
  );
  for (int lane = range.minLane; lane <= range.maxLane; ++lane) {
    for (int row = range.minRow; row <= range.maxRow; ++row) {
      final double x = (lane - 2) * kLanePitch - trackX;
      final double z = (row - kRowCentre) * kRowPitch + trackZ;
      if (frustum.intersects(
        Vec3(x - kCellHalfWidth, -kCellHalfHeight, z - kCellHalfDepth),
        Vec3(x + kCellHalfWidth, kCellHalfHeight, z + kCellHalfDepth),
      )) {
        result.add(SceneCell(lane, row));
      }
    }
  }
  return result;
}

// ---------------------------------------------------------------------------
// Projections — NativeSceneCamera.cpp:98-121, NativeViewer.cpp:283-292.
// ---------------------------------------------------------------------------

/// NativeSceneCamera.cpp:100-101 — the archive/browse projection offset.
double archiveOffsetFor({required bool cinema, required String mode, required double detail}) =>
    (cinema || mode == 'boot') ? 0 : 1 - smoothStep5((detail - kArchiveDetailStart) / kArchiveDetailSpan);

/// NativeSceneCamera.cpp:98-103 — the projection submitted to the GPU.
///
/// near/far are 5/300 and the 0.16/0.20 terms land in `values[8]` (element
/// (0,2)) and `values[9]` (element (1,2)), shifting the projection centre.
Mat4 sceneProjection({
  required double fovDegrees,
  required double width,
  required double height,
  required double archiveOffset,
}) {
  final Mat4 projection = Mat4.perspective(fovDegrees, width / height, kSceneNear, kSceneFar);
  projection.values[8] += kArchiveOffsetX * archiveOffset;
  projection.values[9] += kArchiveOffsetY * archiveOffset;
  return projection;
}

/// NativeSceneCamera.cpp:113-121 — the cull/pick projection.
///
/// far follows the fog (`min(300, max(6, fogFar + 8))`), values[0] and values[5]
/// are divided by 1.18 (an 18% wider view), and the centre offset is copied from
/// the main projection rather than recomputed.
Mat4 cullProjection({
  required double fovDegrees,
  required double width,
  required double height,
  required double fogFar,
  double archiveOffset = 0,
}) {
  final Mat4 projection = Mat4.perspective(
    fovDegrees,
    width / height,
    kSceneNear,
    math.min(kSceneFar, math.max(kCullMinFar, fogFar + kCullFogMargin)),
  );
  projection.values[0] /= kCullExpansion;
  projection.values[5] /= kCullExpansion;
  projection.values[8] = kArchiveOffsetX * archiveOffset;
  projection.values[9] = kArchiveOffsetY * archiveOffset;
  return projection;
}

/// NativeViewer.cpp:287-292 — the assembly viewer projection.
///
/// Always 34 degrees with a 0.3..120 clip; below an aspect of 1.05 both
/// `values[0]` and `values[5]` are multiplied by
/// `min(1.15, aspect / 0.85) / (1 + 0.08 * spread)`.
Mat4 viewerProjection({required double width, required double height, required double spread}) {
  final double aspect = width / height;
  final Mat4 projection = Mat4.perspective(kViewerFov, aspect, kViewerNear, kViewerFar);
  if (aspect < kPortraitAspect) {
    final double zoom =
        math.min(kViewerZoomCap, aspect / kViewerZoomAspectBase) / (1 + kViewerSpreadZoom * spread);
    projection.values[0] *= zoom;
    projection.values[5] *= zoom;
  }
  return projection;
}

/// NativeSceneCamera.cpp:55-71 — the wall framing anchors.
///
/// Returns the horizontal/vertical anchor and the view span for the current
/// breakpoint. The portrait branch replaces the span and both anchors; the
/// compact branch only replaces the anchors.
class WallFraming {
  const WallFraming({required this.anchorX, required this.anchorY, required this.viewSpan});

  final double anchorX;
  final double anchorY;
  final double viewSpan;
}

WallFraming wallFraming({
  required double baseSpan,
  required double width,
  required double height,
  required double detail,
}) {
  final double aspect = width / height;
  final bool portrait = aspect < kPortraitAspect;
  final bool compact = !portrait && width < kCompactWidth;
  double viewSpan = math.max(baseSpan, baseSpan * (16.0 / 9) / aspect);
  double anchorX = kDefaultAnchorX;
  double anchorY = kDefaultAnchorY;
  if (portrait) {
    final double portraitDetail = math.max(
      6.3 / aspect,
      3.7 * height / math.max(100.0, 0.54 * height - 156),
    );
    viewSpan = math.max(baseSpan, lerpDouble(8.4 / aspect, portraitDetail, detail));
    anchorX = 0.5;
    anchorY = kPortraitAnchorY + kPortraitAnchorYBias / height;
  } else if (compact) {
    anchorX = kCompactAnchorX;
    anchorY = kCompactAnchorY;
  }
  return WallFraming(anchorX: anchorX, anchorY: anchorY, viewSpan: viewSpan);
}

/// NativeSceneCamera.cpp:93 — the fov back-solve from the desired span.
///
/// `2 * atan(span / (2 * distance))` in degrees.
double fovForSpan(double span, double distance) =>
    2 * math.atan(span / (2 * distance)) / (math.pi / 180);
