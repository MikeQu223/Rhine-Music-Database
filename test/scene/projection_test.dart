// Contract tests for lib/scene/scene_math.dart.
//
// Every expectation below is copied from the Qt implementation at baseline
// 8ed3067b0812eb2612f7841ec127a6e8ca93231b:
//   Qt/src/SceneMath.h (45 lines), Qt/src/SceneMath.cpp (219 lines),
//   Qt/src/NativeSceneCamera.cpp (98, 100-121, 159-171),
//   Qt/src/NativeViewer.cpp (283-292),
//   Qt/src/NativeScene.cpp (63-78).
//
// STATUS: written, deliberately NOT executed in this phase. The task contract
// forbids dart test / flutter test / analyze / build here.

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:rhine_music_database/scene/picking.dart';
import 'package:rhine_music_database/scene/scene_math.dart';

/// 32-byte stride, little endian Float32 positions (NativePicking.cpp:119).
Uint8List _vertexBytes(List<List<double>> positions) {
  final ByteData data = ByteData(positions.length * 32);
  for (int index = 0; index < positions.length; ++index) {
    data.setFloat32(index * 32, positions[index][0], Endian.little);
    data.setFloat32(index * 32 + 4, positions[index][1], Endian.little);
    data.setFloat32(index * 32 + 8, positions[index][2], Endian.little);
  }
  return data.buffer.asUint8List();
}

/// Little endian Uint32 indices (NativePicking.cpp:125).
Uint8List _indexBytes(List<int> indices) {
  final ByteData data = ByteData(indices.length * 4);
  for (int index = 0; index < indices.length; ++index) {
    data.setUint32(index * 4, indices[index], Endian.little);
  }
  return data.buffer.asUint8List();
}

void main() {
  // SceneMath.cpp:26-29 — a zero-length vector is returned unchanged.
  group('Vec3 matches Qt SceneMath Vector', () {
    test('operators, dot, cross, length', () {
      const Vec3 a = Vec3(1, 2, 3);
      const Vec3 b = Vec3(4, 5, 6);
      expect(a.x + b.x, 5);
      final Vec3 sum = a + b;
      expect(<double>[sum.x, sum.y, sum.z], <double>[5, 7, 9]);
      final Vec3 difference = b - a;
      expect(<double>[difference.x, difference.y, difference.z], <double>[3, 3, 3]);
      final Vec3 scaled = a * 2.5;
      expect(<double>[scaled.x, scaled.y, scaled.z], <double>[2.5, 5.0, 7.5]);
      expect(a.dot(b), 32);
      final Vec3 cross = a.cross(b);
      expect(<double>[cross.x, cross.y, cross.z], <double>[-3, 6, -3]);
      expect(Vec3(3, 4, 0).length, 5);
    });

    test('normalized of a zero vector returns the vector unchanged', () {
      const Vec3 zero = Vec3.zero;
      final Vec3 result = zero.normalized();
      expect(<double>[result.x, result.y, result.z], <double>[0, 0, 0]);
    });

    test('normalized divides by length', () {
      final Vec3 result = const Vec3(0, 3, 4).normalized();
      expect(result.x, closeTo(0, 1e-15));
      expect(result.y, closeTo(0.6, 1e-15));
      expect(result.z, closeTo(0.8, 1e-15));
    });

    test('lerp is from + (to - from) * amount', () {
      final Vec3 result = const Vec3(0, 0, 0).lerp(const Vec3(4, 8, 12), 0.25);
      expect(<double>[result.x, result.y, result.z], <double>[1, 2, 3]);
    });
  });

  // SceneMath.h:22-24 — column-major storage, index = column * 4 + row.
  group('Mat4 storage convention', () {
    test('default value is the identity matrix in column-major order', () {
      final Mat4 identity = Mat4();
      expect(
        identity.values.toList(),
        <double>[1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1],
      );
    });

    test('camera() writes basis vectors into column 0/1/2 and translation into column 3', () {
      final Mat4 view = Mat4.camera(const Vec3(0, 0, 10), const Vec3(0, 0, 0));
      // Columns are x, y, z basis + translation, so the +z basis is values[8..10].
      expect(view.values[2], 0);
      expect(view.values[8], 0);
      expect(view.values[9], 0);
      expect(view.values[10], closeTo(1, 1e-15));
      expect(view.values[12], 0);
      expect(view.values[13], 0);
      expect(view.values[14], 10);
      expect(view.values[15], 1);
      expect(view.values[3], 0);
      expect(view.values[7], 0);
      expect(view.values[11], 0);
    });

    test('compose() of the identity rotation is a pure translation', () {
      final Mat4 composed = Mat4.compose(const Vec3(1, 2, 3), Vec3.zero);
      expect(
        composed.values.toList(),
        <double>[1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 1, 2, 3, 1],
      );
    });
  });

  // SceneMath.cpp:64-78.
  group('Mat4.perspective matches Qt frustum construction', () {
    test('symmetric bounds make the (0,2) and (1,2) terms exactly zero', () {
      final Mat4 projection = Mat4.perspective(6.15, 1920 / 1080, 5, 300);
      // a = (right + left) / (right - left) == 0 and b likewise.
      expect(projection.values[8], 0);
      expect(projection.values[9], 0);
      expect(projection.values[11], -1);
      expect(projection.values[15], 0);
      expect(projection.values[3], 0);
      expect(projection.values[7], 0);
      expect(projection.values[1], 0);
      expect(projection.values[2], 0);
      expect(projection.values[4], 0);
      expect(projection.values[6], 0);
      expect(projection.values[12], 0);
      expect(projection.values[13], 0);
    });

    test('x / y / c / d reproduce the Qt closed form', () {
      const double fov = 6.15;
      const double aspect = 1920 / 1080;
      const double near = 5;
      const double far = 300;
      final double top = near * math.tan(math.pi / 180 * 0.5 * fov);
      final double height = 2 * top;
      final double width = aspect * height;
      final double left = -0.5 * width;
      final double right = left + width;
      final double bottom = top - height;

      final Mat4 projection = Mat4.perspective(fov, aspect, near, far);
      // values[0] = 2 * near / (right - left); values[5] = 2 * near / (top - bottom).
      expect(projection.values[0], closeTo(2 * near / (right - left), 1e-12));
      expect(projection.values[5], closeTo(2 * near / (top - bottom), 1e-12));
      // Symmetric frustum: values[0] == 1 / (aspect * tan(fov / 2)).
      expect(projection.values[0], closeTo(1 / (aspect * math.tan(math.pi / 360 * fov)), 1e-12));
      expect(projection.values[5], closeTo(1 / math.tan(math.pi / 360 * fov), 1e-12));
      expect(projection.values[10], closeTo(-(far + near) / (far - near), 1e-15));
      expect(projection.values[14], closeTo(-2 * far * near / (far - near), 1e-15));
    });
  });

  // SceneMath.cpp:96-108, 110-157, 158-171.
  group('Mat4 multiply / inverse / point / direction', () {
    test('operator* multiplies this by other with column-major indexing', () {
      final Mat4 left = Mat4.compose(const Vec3(1, 0, 0), Vec3.zero);
      final Mat4 right = Mat4.compose(const Vec3(0, 2, 0), Vec3.zero);
      final Mat4 product = left * right;
      // Translation columns add: this * other applies other first.
      expect(product.values[12], 1);
      expect(product.values[13], 2);
      expect(product.values[14], 0);
      final Mat4 identity = Mat4();
      expect((left * identity).values.toList(), left.values.toList());
    });

    test('inverse() of a translation is the negated translation', () {
      final Mat4 inverse = Mat4.compose(const Vec3(2, -3, 4), Vec3.zero).inverse();
      expect(inverse.values[12], closeTo(-2, 1e-12));
      expect(inverse.values[13], closeTo(3, 1e-12));
      expect(inverse.values[14], closeTo(-4, 1e-12));
      expect(inverse.values[15], closeTo(1, 1e-12));
    });

    test('inverse() of a singular matrix is the all-zero matrix, not an exception', () {
      final Mat4 singular = Mat4(List<double>.filled(16, 0));
      final Mat4 inverse = singular.inverse();
      expect(inverse.values.toList(), List<double>.filled(16, 0));
    });

    test('point() divides by w exactly like Qt', () {
      // With the identity matrix w == 1 and the point is unchanged.
      final Vec3 point = Mat4().point(const Vec3(1, 2, 3));
      expect(<double>[point.x, point.y, point.z], <double>[1, 2, 3]);
      // A perspective matrix puts -z into w, so the divide is observable.
      final Mat4 projection = Mat4.perspective(90, 1, 1, 100);
      final Vec3 projected = projection.point(const Vec3(0, 0, -2));
      // w == 1 / ((-1) * -2) == 0.5 and (c * -2 + d) * w == (2 / 99) * 0.5 == 1 / 99.
      expect(projected.z, closeTo(1 / 99, 1e-12));
    });

    test('direction() ignores translation and normalizes', () {
      final Vec3 direction = Mat4.compose(const Vec3(10, 10, 10), Vec3.zero).direction(const Vec3(0, 0, 5));
      expect(<double>[direction.x, direction.y, direction.z], <double>[0, 0, 1]);
    });

    test('toBytes narrows to 16 Float32 values in stored order', () {
      final Mat4 projection = Mat4.perspective(34, 1, 0.3, 120);
      expect(projection.toBytes().length, 64);
      expect(projection.toJson().length, 16);
      expect(projection.toJson()[10], closeTo(projection.values[10], 1e-15));
    });
  });

  // SceneMath.cpp:184-217.
  group('Frustum matches Qt plane extraction and culling', () {
    test('plane order matches Qt extraction: left, right, bottom, top, far at [4], near at [5]', () {
      final Mat4 projection = Mat4.perspective(90, 1, 1, 100);
      final Frustum frustum = Frustum(projection);
      expect(frustum.planes.length, 6);
      // For perspective(90, 1, 1, 100): x = y = 1, c = -101/99, d = -200/99.
      // _extractPlanes normalizes each plane by its xyz length (SceneMath.cpp:184-197).
      // Index 4 (component 2, sign -1) is the Qt z-slot holding the far plane:
      //   (0, 0, 2/99, 200/99); _extractPlanes divides only by the xyz length
      //   |2/99|, so this becomes (0, 0, 1, 100), i.e. z + 100 = 0 -> z = -100.
      // Index 5 (sign +1) is the near plane:
      //   (0, 0, -200/99, -200/99); xyz length 200/99 gives
      //   (0, 0, -1, -1), i.e. -z - 1 = 0 -> z = -1.
      // Do not include d in the length: a 4-vector normalization gives a
      // non-unit normal (e.g. 0.0099995, 0.99995) and makes the test false-red.
      const double a = 0.7071067811865476;
      expect(frustum.planes[0][0], closeTo(-a, 1e-9));
      expect(frustum.planes[0][2], closeTo(-a, 1e-9));
      expect(frustum.planes[1][0], closeTo(a, 1e-9));
      expect(frustum.planes[1][2], closeTo(-a, 1e-9));
      expect(frustum.planes[2][1], closeTo(-a, 1e-9));
      expect(frustum.planes[3][1], closeTo(a, 1e-9));
      expect(frustum.planes[4][2], closeTo(1, 1e-9));
      expect(frustum.planes[4][3], closeTo(100, 1e-9));
      expect(frustum.planes[5][2], closeTo(-1, 1e-9));
      expect(frustum.planes[5][3], closeTo(-1, 1e-9));
    });

    test('intersects keeps the near box and rejects behind and beyond the far plane', () {
      final Mat4 view = Mat4.camera(const Vec3(0, 0, 10), const Vec3(0, 0, 0)).inverse();
      final Frustum frustum = Frustum(Mat4.perspective(90, 1, 1, 100) * view);
      expect(frustum.intersects(const Vec3(-1, -1, 4), const Vec3(1, 1, 6)), isTrue);
      // z = 15 is behind the camera at z = 10.
      expect(frustum.intersects(const Vec3(-1, -1, 14), const Vec3(1, 1, 16)), isFalse);
      // z = -200 is further than near + far.
      expect(frustum.intersects(const Vec3(-1, -1, -201), const Vec3(1, 1, -199)), isFalse);
    });

    test('intersectsSphere rejects only when the centre is more than one radius out', () {
      final Mat4 view = Mat4.camera(const Vec3(0, 0, 10), const Vec3(0, 0, 0)).inverse();
      final Frustum frustum = Frustum(Mat4.perspective(90, 1, 1, 100) * view);
      expect(frustum.intersectsSphere(const Vec3(0, 0, 5), 0.1), isTrue);
      expect(frustum.intersectsSphere(const Vec3(0, 0, 20), 1), isFalse);
      expect(frustum.intersectsSphere(const Vec3(0, 0, 20), 20), isTrue);
    });
  });

  // NativePicking.cpp:196-249; T41-T01: hit error at most one card.
  group('NativePicking matches the Qt BVH raycast', () {
    NativePicking trianglePicker() => NativePicking.fromJson(
          manifest: <String, Object?>{
            'meshes': <Object?>[
              <String, Object?>{
                'vertexStart': 0,
                'vertexCount': 3,
                'start': 0,
                'count': 3,
              },
            ],
          },
          vertices: _vertexBytes(<List<double>>[
            <double>[0, 0, 0],
            <double>[10, 0, 0],
            <double>[0, 10, 0],
          ]),
          indexBytes: _indexBytes(<int>[0, 1, 2]),
        );

    test('raycast returns origin + direction * best on a front-facing hit', () {
      final NativePicking picker = trianglePicker();
      final Map<String, double> hit =
          picker.raycast(0, <Object?>[2, 2, 5], <Object?>[0, 0, -1], 2);
      expect(hit.keys.toSet(), <String>{'x', 'y', 'z'});
      expect(hit['x'], closeTo(2, 1e-9));
      expect(hit['y'], closeTo(2, 1e-9));
      expect(hit['z'], closeTo(0, 1e-9));
      // The atom's acceptance bound: the hit must be within one card of the
      // requested point. The exact assertions above are stricter; these keep
      // the card-sized error budget explicit.
      expect((hit['x']! - 2).abs(),
          lessThanOrEqualTo(kCardMaxX - kCardMinX));
      expect((hit['y']! - 2).abs(),
          lessThanOrEqualTo(kCardMaxY - kCardMinY));
      expect((hit['z']! - 0).abs(),
          lessThanOrEqualTo(kCardMaxZ - kCardMinZ));
    });

    test('miss, out-of-range mesh and wrong vector length return an empty map', () {
      final NativePicking picker = trianglePicker();
      expect(picker.raycast(0, <Object?>[20, 20, 5], <Object?>[0, 0, -1], 2),
          isEmpty);
      expect(picker.raycast(9, <Object?>[2, 2, 5], <Object?>[0, 0, -1], 2),
          isEmpty);
      expect(picker.raycast(0, <Object?>[2, 2], <Object?>[0, 0, -1], 2),
          isEmpty);
      expect(picker.raycast(0, <Object?>[2, 2, 5], <Object?>[0, 0], 2),
          isEmpty);
    });

    test('side 1 flips the winding; side 2 accepts both', () {
      final NativePicking picker = trianglePicker();
      // NativePicking.cpp:152-154 swaps first and third when side == 1, which
      // reverses the normal: the +z face now misses and the -z face hits.
      expect(picker.raycast(0, <Object?>[2, 2, 5], <Object?>[0, 0, -1], 1),
          isEmpty,
          reason: 'side 1 swapped the winding; the original front face is culled');
      final Map<String, double> back =
          picker.raycast(0, <Object?>[2, 2, -5], <Object?>[0, 0, 1], 1);
      expect(back['x'], closeTo(2, 1e-9));
      expect(back['y'], closeTo(2, 1e-9));
      expect(back['z'], closeTo(0, 1e-9),
          reason: 'after the swap this is the front face');

      // NativePicking.cpp:160-163: side 2 accepts a positive denominator too.
      for (final List<Object?> ray in <List<Object?>>[
        <Object?>[2, 2, 5, 0, 0, -1],
        <Object?>[2, 2, -5, 0, 0, 1],
      ]) {
        final Map<String, double> hit = picker.raycast(
          0,
          ray.sublist(0, 3),
          ray.sublist(3),
          2,
        );
        expect(hit['x'], closeTo(2, 1e-9));
        expect(hit['y'], closeTo(2, 1e-9));
        expect(hit['z'], closeTo(0, 1e-9));
      }
    });
  });

  // NativeSceneCamera.cpp:100-103.
  group('archive offset 0.16 / 0.20', () {
    test('archiveOffsetFor is zero in boot and cinema, full at detail 0', () {
      expect(archiveOffsetFor(cinema: false, mode: 'boot', detail: 0), 0);
      expect(archiveOffsetFor(cinema: true, mode: 'archive', detail: 0), 0);
      expect(archiveOffsetFor(cinema: false, mode: 'archive', detail: 0), 1);
    });

    test('archiveOffsetFor follows 1 - smooth((detail - 0.25) / 0.55)', () {
      expect(archiveOffsetFor(cinema: false, mode: 'archive', detail: 0.25), 1);
      expect(archiveOffsetFor(cinema: false, mode: 'archive', detail: 0.525), closeTo(0.5, 1e-15));
      expect(archiveOffsetFor(cinema: false, mode: 'archive', detail: 0.8), 0);
      expect(archiveOffsetFor(cinema: false, mode: 'archive', detail: 1), 0);
    });

    test('sceneProjection uses near 5 / far 300 and lands the offsets in values[8]/[9]', () {
      final Mat4 boot = sceneProjection(fovDegrees: 6.15, width: 1920, height: 1080, archiveOffset: 0);
      expect(boot.values[8], 0);
      expect(boot.values[9], 0);
      expect(boot.values[10], closeTo(-(300 + 5) / (300 - 5), 1e-15));
      expect(boot.values[14], closeTo(-2 * 300 * 5 / (300 - 5), 1e-15));

      final Mat4 browsing = sceneProjection(fovDegrees: 6.15, width: 1920, height: 1080, archiveOffset: 1);
      expect(browsing.values[8], closeTo(0.16, 1e-15));
      expect(browsing.values[9], closeTo(0.20, 1e-15));

      final Mat4 half = sceneProjection(fovDegrees: 6.15, width: 1920, height: 1080, archiveOffset: 0.5);
      expect(half.values[8], closeTo(0.08, 1e-15));
      expect(half.values[9], closeTo(0.10, 1e-15));
      // The offset moves the projection centre, never the depth terms.
      expect(half.values[10], boot.values[10]);
      expect(half.values[14], boot.values[14]);
    });
  });

  // NativeSceneCamera.cpp:113-121.
  group('cull projection widens by 1.18 and tracks the fog', () {
    test('values[0] and values[5] are divided by 1.18', () {
      final Mat4 plain = Mat4.perspective(6.15, 1920 / 1080, 5, 47 + 8);
      final Mat4 cull = cullProjection(fovDegrees: 6.15, width: 1920, height: 1080, fogFar: 47);
      expect(cull.values[0], closeTo(plain.values[0] / 1.18, 1e-15));
      expect(cull.values[5], closeTo(plain.values[5] / 1.18, 1e-15));
    });

    test('far is min(300, max(6, fogFar + 8)) and near stays 5', () {
      final Mat4 nearFog = cullProjection(fovDegrees: 6.15, width: 1920, height: 1080, fogFar: -10);
      final Mat4 referenceNear = Mat4.perspective(6.15, 1920 / 1080, 5, 6);
      expect(nearFog.values[10], closeTo(referenceNear.values[10], 1e-15));
      expect(nearFog.values[14], closeTo(referenceNear.values[14], 1e-15));

      final Mat4 farFog = cullProjection(fovDegrees: 6.15, width: 1920, height: 1080, fogFar: 400);
      final Mat4 referenceFar = Mat4.perspective(6.15, 1920 / 1080, 5, 300);
      expect(farFog.values[10], closeTo(referenceFar.values[10], 1e-15));
    });

    test('the cull projection reuses the main projection centre offset', () {
      final Mat4 cull = cullProjection(
        fovDegrees: 6.15,
        width: 1920,
        height: 1080,
        fogFar: 47,
        archiveOffset: 1,
      );
      expect(cull.values[8], closeTo(0.16, 1e-15));
      expect(cull.values[9], closeTo(0.20, 1e-15));
    });
  });

  // NativeViewer.cpp:283-292.
  group('viewer projection 34 / 0.3 / 120', () {
    test('landscape uses perspective(34, aspect, 0.3, 120) unchanged', () {
      final Mat4 projection = viewerProjection(width: 1920, height: 1080, spread: 0);
      final Mat4 reference = Mat4.perspective(34, 1920 / 1080, 0.3, 120);
      expect(projection.values.toList(), reference.values.toList());
      expect(projection.values[10], closeTo(-(120 + 0.3) / (120 - 0.3), 1e-15));
      expect(projection.values[14], closeTo(-2 * 120 * 0.3 / (120 - 0.3), 1e-15));
    });

    test('portrait multiplies values[0] and values[5] by the Qt zoom', () {
      const double width = 1000;
      const double height = 1400;
      const double aspect = width / height;
      final Mat4 base = Mat4.perspective(34, aspect, 0.3, 120);
      final Mat4 projection = viewerProjection(width: width, height: height, spread: 0);
      final double zoom = math.min(1.15, aspect / 0.85);
      expect(aspect < kPortraitAspect, isTrue);
      expect(projection.values[0], closeTo(base.values[0] * zoom, 1e-15));
      expect(projection.values[5], closeTo(base.values[5] * zoom, 1e-15));
      expect(projection.values[10], base.values[10]);
    });

    test('portrait zoom shrinks as the spread spring grows', () {
      const double width = 1000;
      const double height = 1400;
      final Mat4 collapsed = viewerProjection(width: width, height: height, spread: 0);
      final Mat4 exploded = viewerProjection(width: width, height: height, spread: 1);
      expect(exploded.values[5], closeTo(collapsed.values[5] / 1.08, 1e-15));
    });

    test('the zoom is capped at 1.15 for very narrow windows', () {
      const double width = 1000;
      const double height = 1010;
      final Mat4 base = Mat4.perspective(34, width / height, 0.3, 120);
      final Mat4 projection = viewerProjection(width: width, height: height, spread: 0);
      expect(width / height < kPortraitAspect, isTrue);
      expect(width / height / 0.85 > 1.15, isTrue);
      expect(projection.values[5], closeTo(base.values[5] * 1.15, 1e-15));
    });
  });

  // NativeScene.cpp:63-78, NativeSceneCamera.cpp:109-111, 159-171.
  group('cell geometry matches the Qt wall', () {
    test('cellPosition uses lane pitch 5.2, row pitch 0.62, y -4.6, row centre 15.5', () {
      final Vec3 origin = cellPosition(const SceneCell(2, 12));
      expect(origin.x, 0);
      expect(origin.y, -4.6);
      // 12 - 15.5 == -3.5 and -3.5 * 0.62 == -2.17, the rail rest value.
      expect(origin.z, closeTo(-2.17, 1e-15));

      final Vec3 shifted = cellPosition(const SceneCell(0, 15));
      expect(shifted.x, closeTo(-10.4, 1e-15));
      expect(shifted.z, closeTo(-0.31, 1e-15));
    });

    test('trackedCellPosition subtracts trackX and adds trackZ', () {
      final Vec3 position = trackedCellPosition(const SceneCell(2, 12), trackX: 3, trackZ: 5);
      expect(position.x, closeTo(-3, 1e-15));
      expect(position.z, closeTo(2.83, 1e-15));
    });

    test('fileLocation maps the nth record of a lane to row 12 + n', () {
      expect(fileLocation(lane: 2, indexInLane: 0), const SceneCell(2, 12));
      expect(fileLocation(lane: 4, indexInLane: 7), const SceneCell(4, 19));
    });

    test('intersectsCard uses the Qt card box relative to the card position', () {
      final Vec3 card = cellPosition(const SceneCell(2, 12));
      final Mat4 view =
          Mat4.camera(Vec3(card.x, card.y + 2, card.z + 40), card).inverse();
      final Frustum frustum = Frustum(Mat4.perspective(34, 1920 / 1080, 5, 300) * view);
      expect(intersectsCard(frustum, card), isTrue);
      expect(intersectsCard(frustum, Vec3(card.x, card.y, card.z + 100)), isFalse);
    });

    test('cellIndexRange follows the Qt lane/row reverse solve', () {
      final CellIndexRange range = cellIndexRange(
        minimum: const Vec3(0, -6.5, -2.17),
        maximum: const Vec3(0, 6.5, -2.17),
        trackX: 0,
        trackZ: 0,
      );
      // minLane = floor((0 - 2.8) / 5.2 + 2) - 1 == 0
      // maxLane = ceil((0 + 2.8) / 5.2 + 2) + 1 == 4
      expect(range.minLane, 0);
      expect(range.maxLane, 4);
      // minRow = floor((-2.17 - 0.6) / 0.62 + 15.5) - 2 == 9
      // maxRow = ceil((-2.17 + 0.6) / 0.62 + 15.5) + 2 == 15
      expect(range.minRow, 9);
      expect(range.maxRow, 15);
    });

    test('visibleCells returns the culled cells and includes the centre card', () {
      final Vec3 card = cellPosition(const SceneCell(2, 12));
      final Mat4 view = Mat4.camera(Vec3(card.x, card.y + 2, card.z + 40), card).inverse();
      final Mat4 projection = cullProjection(
        fovDegrees: 34,
        width: 1920,
        height: 1080,
        fogFar: 100,
        archiveOffset: 0,
      );
      final List<SceneCell> cells = visibleCells(projection: projection, view: view, trackX: 0, trackZ: 0);
      expect(cells, isNotEmpty);
      expect(cells, contains(const SceneCell(2, 12)));
      // Qt does not clamp lanes or rows, so the list may legitimately include
      // out-of-range indices that the caller folds back with wrap(cell.lane, 5).
      expect(cells.toSet().length, cells.length);
    });
  });

  // SceneMath port of the shared easing helpers used by the scene and viewer.
  group('SceneMotion easing helpers', () {
    test('smoothStep5 is the clamped quintic smoothstep', () {
      expect(smoothStep5(-1), 0);
      expect(smoothStep5(0), 0);
      expect(smoothStep5(1), 1);
      expect(smoothStep5(2), 1);
      expect(smoothStep5(0.5), closeTo(0.5, 1e-15));
    });

    test('easeStep is the clamped cubic smoothstep', () {
      expect(easeStep(-1), 0);
      expect(easeStep(0.5), closeTo(0.5, 1e-15));
      expect(easeStep(1), 1);
    });

    test('bellCurve is exp(-0.5 * (v / width)^2)', () {
      expect(bellCurve(0, 3.8), 1);
      expect(bellCurve(3.8, 3.8), closeTo(math.exp(-0.5), 1e-15));
    });

    test('Spring.damp follows the Qt critically damped update', () {
      final Spring spring = Spring(0, 0);
      spring.damp(1, 8, 1 / 60);
      final double delta = 0 - 1;
      final double impulse = 0 + 8 * delta;
      final double decay = math.exp(-8 / 60);
      expect(spring.value, closeTo(1 + (delta + impulse / 60) * decay, 1e-15));
      expect(spring.velocity, closeTo((0 - 8 * impulse / 60) * decay, 1e-15));
    });

    test('trackCurve interpolates between keys and clamps outside them', () {
      const List<CurveKey> keys = <CurveKey>[
        CurveKey(34.24, 0),
        CurveKey(36.04, 1),
      ];
      expect(trackCurve(keys, 34), 0);
      expect(trackCurve(keys, 40), 1);
      expect(trackCurve(keys, 35.14), closeTo(0.5, 1e-9));
    });
  });
}
