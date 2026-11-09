/// Faithful Dart port of the Qt native BVH picker used by the 3D wall.
///
/// Source of truth: `Qt/src/NativePicking.h` (19 lines) and
/// `Qt/src/NativePicking.cpp` (249 lines) at commit
/// 8ed3067b0812eb2612f7841ec127a6e8ca93231b. The Qt class keeps one static
/// collision tree per GLB part in native contiguous memory so the UI thread
/// never walks thousands of nodes through the JS bridge
/// (NativePicking.h:7 — "将静态模型的碰撞树放在原生连续内存中，避免 JS GC 反复遍历
/// 大量树节点").
///
/// Conventions copied verbatim from the C++:
///  * Scalars are `double`; a miss is `double.infinity`
///    (NativePicking.cpp:27-28, 162, 168, 174, 177) and the final hit is
///    filtered with `std::isfinite` (NativePicking.cpp:243).
///  * A ray is `origin + direction * t` with `t >= 0` because the slab test
///    starts at `near = 0` (NativePicking.cpp:40-41).
///  * Vertex stride is 32 bytes and only the first 12 bytes are read; positions
///    are little endian Float32 and indices little endian Uint32
///    (NativePicking.cpp:119, 125).
///  * `side` keeps the Qt winding contract: `1` swaps the first and third
///    vertex, `2` also accepts back faces, any other value only front faces
///    (NativePicking.cpp:152-169). The single Qt caller passes `2`
///    (NativeSceneInput.cpp:77).
///
/// STATUS: written, deliberately NOT executed. `dart analyze`, `dart test`,
/// `flutter test` and the repository verifiers are forbidden for this atom, so
/// RED and GREEN are both unverified (RED/GREEN not run).
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'scene_math.dart';

// ---------------------------------------------------------------------------
// Local helpers. Each mirrors one `std::` or `QJsonValue` call from the C++.
// ---------------------------------------------------------------------------

// `std::array<double, 3>` component access (NativePicking.cpp:30-33, 42-50).
double _component(Vec3 vector, int axis) {
  if (axis == 0) {
    return vector.x;
  }
  return axis == 1 ? vector.y : vector.z;
}

// `std::swap` on the triangle order (NativePicking.cpp:95-99 permutes it).
void _swap(List<int> values, int left, int right) {
  final int value = values[left];
  values[left] = values[right];
  values[right] = value;
}

// Deterministic stand-in for `std::nth_element(triangles.begin() + first,
// triangles.begin() + middle, triangles.begin() + first + count, less)`
// (NativePicking.cpp:95-99).
//
// Both algorithms share the same postcondition: after the call the element at
// `nth` is the one a full sort would put there, nothing in `[first, nth)` is
// greater and nothing in `(nth, last)` is less. The resulting permutation is
// unspecified in libstdc++ as well, so the BVH may partition differently than
// a given libstdc++ build; the node boxes then cover different subsets, but
// every box still covers exactly the triangles of its range and
// [PickingMesh.visit] minimises over all of them, so the hit distance is
// unchanged.
void _nthElement(
  List<int> values,
  int first,
  int nth,
  int last,
  bool Function(int left, int right) less,
) {
  int begin = first;
  int end = last;
  while (end - begin > 1) {
    final int middle = begin + (end - begin) ~/ 2;
    // libstdc++'s `__unguarded_partition_pivot` also pivots on the median of
    // the first, middle and last element; the exact slot is not observable.
    int slot;
    if (less(values[begin], values[middle])) {
      if (less(values[middle], values[end - 1])) {
        slot = middle;
      } else {
        slot = less(values[begin], values[end - 1]) ? end - 1 : begin;
      }
    } else {
      if (less(values[begin], values[end - 1])) {
        slot = begin;
      } else {
        slot = less(values[middle], values[end - 1]) ? end - 1 : middle;
      }
    }
    _swap(values, slot, end - 1);
    final int pivot = values[end - 1];
    int store = begin;
    for (int index = begin; index < end - 1; ++index) {
      if (less(values[index], pivot)) {
        _swap(values, index, store);
        ++store;
      }
    }
    _swap(values, store, end - 1);
    if (store == nth) {
      return;
    }
    if (nth < store) {
      end = store;
    } else {
      begin = store + 1;
    }
  }
}

// `QJsonValue::toInt(defaultValue)` (NativePicking.cpp:107-110): a finite,
// integral, int32 representable number wins, everything else keeps the default.
int _jsonInt(Object? value, int fallback) {
  if (value is num) {
    final double number = value.toDouble();
    if (number.isFinite &&
        number >= -2147483648.0 &&
        number <= 2147483647.0 &&
        number == number.truncateToDouble()) {
      return number.toInt();
    }
  }
  return fallback;
}

// `QVariant::toDouble` on a QVariantList element (NativePicking.cpp:238-240):
// numbers convert, booleans become 1/0 and strings are parsed, anything else is
// zero.
double _variantDouble(Object? value) {
  if (value is num) {
    return value.toDouble();
  }
  if (value is bool) {
    return value ? 1 : 0;
  }
  if (value is String) {
    return double.tryParse(value) ?? 0;
  }
  return 0;
}

// `QJsonDocument::fromJson(text).object()` (NativePicking.cpp:223): malformed
// JSON and non-object documents both degrade to an empty object instead of
// throwing.
Map<String, Object?> _jsonObject(String text) {
  Object? decoded;
  try {
    decoded = jsonDecode(text);
  } on FormatException {
    return const <String, Object?>{};
  }
  return decoded is Map<String, Object?> ? decoded : const <String, Object?>{};
}

// `QFile::open(QIODevice::ReadOnly)` followed by `readAll`
// (NativePicking.cpp:216-225); a missing or unreadable path is a soft failure.
// Qt reads bytes and leaves decoding to `QJsonDocument`, so a manifest that is
// not valid UTF-8 also degrades to `null` here instead of throwing.
String? _readText(String path) {
  try {
    return File(path).readAsStringSync();
  } on FileSystemException {
    return null;
  } on FormatException {
    return null;
  }
}

// `vertices.readAll()` / `indices.readAll()` (NativePicking.cpp:224-225).
Uint8List? _readBytes(String path) {
  try {
    return File(path).readAsBytesSync();
  } on FileSystemException {
    return null;
  }
}

// ---------------------------------------------------------------------------
// Box / node / mesh — NativePicking.cpp:26-193.
// ---------------------------------------------------------------------------

/// Axis aligned bounds with the Qt `Box` sentinels.
///
/// A fresh box is empty: [low] is `+infinity` and [high] is `-infinity`
/// (NativePicking.cpp:27-28), so the first [include] installs the point.
class PickingBox {
  /// Creates an empty box.
  PickingBox() : low = _emptyLow, high = _emptyHigh;

  /// Creates a box from explicit bounds.
  PickingBox.fromBounds(this.low, this.high);

  static const Vec3 _emptyLow = Vec3(
    double.infinity,
    double.infinity,
    double.infinity,
  );
  static const Vec3 _emptyHigh = Vec3(
    double.negativeInfinity,
    double.negativeInfinity,
    double.negativeInfinity,
  );

  /// Lower corner (NativePicking.cpp:27).
  Vec3 low;

  /// Upper corner (NativePicking.cpp:28).
  Vec3 high;

  /// Grows the box to contain [point] (NativePicking.cpp:29-34).
  ///
  /// Written with comparisons rather than `min`/`max` calls so the
  /// `std::min`/`std::max` NaN behaviour survives: a NaN coordinate leaves
  /// the box untouched because both comparisons are false.
  void include(Vec3 point) {
    low = Vec3(
      point.x < low.x ? point.x : low.x,
      point.y < low.y ? point.y : low.y,
      point.z < low.z ? point.z : low.z,
    );
    high = Vec3(
      high.x < point.x ? point.x : high.x,
      high.y < point.y ? point.y : high.y,
      high.z < point.z ? point.z : high.z,
    );
  }

  /// Grows the box to contain [box] (NativePicking.cpp:35-38).
  void includeBox(PickingBox box) {
    include(box.low);
    include(box.high);
  }

  /// Whether the ray `origin + direction * t`, cut at [best], reaches the box.
  ///
  /// Slab test from NativePicking.cpp:39-61: `near` starts at 0 and `far` at
  /// [best], a zero direction component only does the range check, and the ray
  /// is rejected as soon as `near > far`.
  bool intersects(Vec3 origin, Vec3 direction, double best) {
    double near = 0;
    double far = best;
    for (int axis = 0; axis < 3; ++axis) {
      final double start = _component(origin, axis);
      final double step = _component(direction, axis);
      final double minimum = _component(low, axis);
      final double maximum = _component(high, axis);
      if (step == 0) {
        if (start < minimum || start > maximum) {
          return false;
        }
        continue;
      }
      double first = (minimum - start) / step;
      double last = (maximum - start) / step;
      if (first > last) {
        final double swap = first;
        first = last;
        last = swap;
      }
      // `std::max(near, first)` and `std::min(far, last)` (NativePicking.cpp:54-55)
      // are written with the argument order of libstdc++ so a NaN bound keeps
      // the previous value on the same side as the C++.
      near = near < first ? first : near;
      far = last < far ? last : far;
      if (near > far) {
        return false;
      }
    }
    return true;
  }
}

/// One BVH node, with the Qt field initialisers kept as written.
///
/// NativePicking.cpp:63-69: [left] and [right] stay `-1` until an inner node
/// is linked, [first] and [count] stay `0` until a leaf is tagged. A [count]
/// of zero is what makes [PickingMesh.visit] descend (NativePicking.cpp:184).
class PickingNode {
  /// Creates an unlinked node.
  PickingNode() : box = PickingBox();

  /// Bounds of every triangle below this node (NativePicking.cpp:64).
  PickingBox box;

  /// Left child index, `-1` for leaves (NativePicking.cpp:65).
  int left = -1;

  /// Right child index, `-1` for leaves (NativePicking.cpp:66).
  int right = -1;

  /// First triangle slot of a leaf (NativePicking.cpp:67).
  int first = 0;

  /// Triangle slots of a leaf, `0` for inner nodes (NativePicking.cpp:68).
  int count = 0;
}

/// One GLB part's collision tree (NativePicking.cpp:70-193).
class PickingMesh {
  /// Creates an empty mesh; [load] or [loadFromBytes] fills it.
  PickingMesh();

  /// Decodes [part] from an in-memory manifest and buffers.
  ///
  /// This is the file-free entry point: [part] is one element of the
  /// `meshes` array of `archive-cassette.json`, [vertices] and [indexBytes]
  /// are `archive-cassette.bin` and `archive-cassette-indices.bin`. A part
  /// that fails the range checks of NativePicking.cpp:111-115 leaves the mesh
  /// empty, which [NativePicking.raycast] rejects through its
  /// `nodes.isEmpty` guard (NativePicking.cpp:235).
  factory PickingMesh.loadFromBytes({
    required Map<String, Object?> part,
    required Uint8List vertices,
    required Uint8List indexBytes,
  }) {
    final PickingMesh mesh = PickingMesh();
    mesh.load(part, vertices, indexBytes);
    return mesh;
  }

  /// Decoded vertex positions (NativePicking.cpp:71).
  final List<Vec3> positions = <Vec3>[];

  /// Index buffer values shifted by `vertexStart` (NativePicking.cpp:72).
  final List<int> indices = <int>[];

  /// Triangle ids in BVH order, a permutation of `0 ... count - 1`
  /// (NativePicking.cpp:73, 129-130).
  final List<int> triangles = <int>[];

  /// BVH nodes, root at index 0 (NativePicking.cpp:74).
  final List<PickingNode> nodes = <PickingNode>[];

  /// Decodes [part] and builds the tree (NativePicking.cpp:106-147).
  ///
  /// Qt always calls this on a freshly value-initialised `Mesh`
  /// (NativePicking.cpp:226-229), so the four lists are reset first and a
  /// repeated call cannot accumulate stale state. Every failure path keeps the
  /// tree empty: a rejected range returns before any work, an index pointing
  /// outside [positions] clears [positions] and [triangles] exactly like
  /// NativePicking.cpp:135-139.
  void load(
    Map<String, Object?> part,
    Uint8List vertices,
    Uint8List indexBytes,
  ) {
    positions.clear();
    indices.clear();
    triangles.clear();
    nodes.clear();
    final int vertexStart = _jsonInt(part['vertexStart'], -1);
    final int vertexCount = _jsonInt(part['vertexCount'], 0);
    final int firstIndex = _jsonInt(part['start'], -1);
    final int indexCount = _jsonInt(part['count'], 0);
    if (vertexStart < 0 ||
        firstIndex < 0 ||
        vertexCount <= 0 ||
        indexCount < 0 ||
        (vertexStart + vertexCount) * 32 > vertices.length ||
        (firstIndex + indexCount) * 4 > indexBytes.length) {
      return;
    }
    // Little endian by contract: QDataStream is not involved, the C++ memcpy's
    // native floats, which are little endian on every target this port ships
    // to (arm64-v8a, x86_64).
    final ByteData vertexData = ByteData.sublistView(vertices);
    for (int index = 0; index < vertexCount; ++index) {
      // 32 byte stride, 12 bytes read, 20 bytes skipped (NativePicking.cpp:119).
      final int offset = (vertexStart + index) * 32;
      positions.add(
        Vec3(
          vertexData.getFloat32(offset, Endian.little),
          vertexData.getFloat32(offset + 4, Endian.little),
          vertexData.getFloat32(offset + 8, Endian.little),
        ),
      );
    }
    final ByteData indexData = ByteData.sublistView(indexBytes);
    for (int index = 0; index < indexCount; ++index) {
      final int offset = (firstIndex + index) * 4;
      // `int(quint32)` in NativePicking.cpp:126 is a two's complement wrap for
      // values above INT_MAX, which `toSigned(32)` reproduces.
      final int value = indexData.getUint32(offset, Endian.little).toSigned(32);
      indices.add(value - vertexStart);
    }
    final int count = indices.length ~/ 3;
    for (int index = 0; index < count; ++index) {
      triangles.add(index);
    }
    final List<PickingBox> boxes = List<PickingBox>.generate(
      count,
      (_) => PickingBox(),
      growable: false,
    );
    for (int index = 0; index < count; ++index) {
      for (int vertex = 0; vertex < 3; ++vertex) {
        final int position = indices[index * 3 + vertex];
        if (position < 0 || position >= positions.length) {
          positions.clear();
          triangles.clear();
          return;
        }
        boxes[index].include(positions[position]);
      }
    }
    // `nodes.reserve(count / 2 + 16)` (NativePicking.cpp:143) is a capacity hint
    // only; Dart grows the list on demand and the resulting tree is identical.
    if (count != 0) {
      build(boxes, 0, count);
    }
  }

  /// Appends the node covering `triangles[first, first + count)` and its
  /// descendants, then returns the new node index (NativePicking.cpp:75-105).
  ///
  /// Leaves hold at most eight triangles (NativePicking.cpp:83). An inner node
  /// splits on the longest box axis (NativePicking.cpp:88-93), partitions the
  /// triangle slots with [PickingBox] centre comparisons on that axis
  /// (NativePicking.cpp:95-99) and recurses, writing [PickingNode.left] and
  /// [PickingNode.right] after both subtrees exist (NativePicking.cpp:100-103).
  int build(List<PickingBox> boxes, int first, int count) {
    final int index = nodes.length;
    nodes.add(PickingNode());
    final PickingBox box = PickingBox();
    for (int slot = first; slot < first + count; ++slot) {
      box.includeBox(boxes[triangles[slot]]);
    }
    nodes[index].box = box;
    if (count <= 8) {
      nodes[index].first = first;
      nodes[index].count = count;
      return index;
    }
    int axis = 0;
    for (int candidate = 1; candidate < 3; ++candidate) {
      if (_component(box.high, candidate) - _component(box.low, candidate) >
          _component(box.high, axis) - _component(box.low, axis)) {
        axis = candidate;
      }
    }
    final int middle = first + count ~/ 2;
    _nthElement(
      triangles,
      first,
      middle,
      first + count,
      (int left, int right) =>
          _component(boxes[left].low, axis) +
              _component(boxes[left].high, axis) <
          _component(boxes[right].low, axis) +
              _component(boxes[right].high, axis),
    );
    final int left = build(boxes, first, middle - first);
    final int right = build(boxes, middle, first + count - middle);
    nodes[index].left = left;
    nodes[index].right = right;
    return index;
  }

  /// Distance along [direction] to triangle [index], or `double.infinity`.
  ///
  /// Port of NativePicking.cpp:148-178: [side] `1` swaps the first and third
  /// vertex (NativePicking.cpp:152-154), a positive denominator is a hit only
  /// for `side == 2` (NativePicking.cpp:160-163), a negative one is flipped
  /// through `sign` (NativePicking.cpp:164-166) and a zero one is a miss
  /// (NativePicking.cpp:167-169). Both barycentric weights must be
  /// non-negative and sum to at most the denominator; the numerator must be
  /// non-negative before it is divided.
  double triangle(int index, Vec3 origin, Vec3 direction, int side) {
    Vec3 first = positions[indices[index * 3]];
    final Vec3 second = positions[indices[index * 3 + 1]];
    Vec3 third = positions[indices[index * 3 + 2]];
    if (side == 1) {
      final Vec3 swap = first;
      first = third;
      third = swap;
    }
    final Vec3 edge1 = second - first;
    final Vec3 edge2 = third - first;
    final Vec3 normal = edge1.cross(edge2);
    double denominator = direction.dot(normal);
    double sign = 1;
    if (denominator > 0) {
      if (side != 2) {
        return double.infinity;
      }
    } else if (denominator < 0) {
      sign = -1;
      denominator = -denominator;
    } else {
      return double.infinity;
    }
    final Vec3 difference = origin - first;
    final double firstWeight = sign * direction.dot(difference.cross(edge2));
    final double secondWeight = sign * direction.dot(edge1.cross(difference));
    if (firstWeight < 0 ||
        secondWeight < 0 ||
        firstWeight + secondWeight > denominator) {
      return double.infinity;
    }
    final double numerator = -sign * difference.dot(normal);
    return numerator < 0 ? double.infinity : numerator / denominator;
  }

  /// Closest hit at or nearer than [best] (NativePicking.cpp:179-192).
  ///
  /// The box test prunes first (NativePicking.cpp:181-183), a leaf scans its
  /// triangle slots while shrinking the running best
  /// (NativePicking.cpp:184-187), and an inner node descends left then right so
  /// the right subtree inherits the left subtree's best. Qt passes `best` by
  /// reference (NativePicking.cpp:186, 189-190); returning it keeps the same
  /// propagation order.
  double visit(
    int index,
    Vec3 origin,
    Vec3 direction,
    int side,
    double best,
  ) {
    final PickingNode node = nodes[index];
    if (!node.box.intersects(origin, direction, best)) {
      return best;
    }
    if (node.count != 0) {
      for (int slot = node.first; slot < node.first + node.count; ++slot) {
        final double distance = triangle(triangles[slot], origin, direction, side);
        // `std::min(best, distance)` (NativePicking.cpp:186).
        if (distance < best) {
          best = distance;
        }
      }
    } else {
      best = visit(node.left, origin, direction, side, best);
      best = visit(node.right, origin, direction, side, best);
    }
    return best;
  }
}

// ---------------------------------------------------------------------------
// Picker — NativePicking.cpp:196-249.
// ---------------------------------------------------------------------------

/// Point picker over the `archive-cassette` collision trees.
///
/// Port of NativePicking.h:8-19 and NativePicking.cpp:196-249: one picker owns
/// the decoded trees of one asset root and answers
/// [raycast](`mesh`, `origin`, `direction`, `side`) queries. NativeSceneInput.cpp:77
/// is the only Qt caller and always passes `side == 2`.
class NativePicking {
  /// Creates a picker that reads the `archive-cassette` triplet from [root] on
  /// the first [prepare] or [raycast].
  NativePicking(this.root);

  /// Creates a picker from an already decoded manifest and buffers.
  ///
  /// [manifest] is the parsed `archive-cassette.json`, [vertices] and
  /// [indexBytes] are `archive-cassette.bin` and
  /// `archive-cassette-indices.bin`. The picker counts as prepared, so a later
  /// [prepare] never touches the file system.
  NativePicking.fromJson({
    required Map<String, Object?> manifest,
    required Uint8List vertices,
    required Uint8List indexBytes,
  }) : root = '' {
    meshes.addAll(_buildMeshes(manifest, vertices, indexBytes));
    prepared = true;
  }

  /// Asset directory holding the `archive-cassette` triplet
  /// (NativePicking.cpp:197, 201-203).
  final String root;

  /// Decoded meshes in manifest order (NativePicking.cpp:198).
  final List<PickingMesh> meshes = <PickingMesh>[];

  /// Whether [prepare] already ran, whether or not it found its files.
  ///
  /// Qt raises the flag before it opens anything (NativePicking.cpp:215), so a
  /// missing triplet is never retried until [trimMemory] resets it
  /// (NativePicking.cpp:205-209).
  bool prepared = false;

  /// Loads and builds every tree once (NativePicking.cpp:211-230).
  ///
  /// The Qt order is preserved: the flag is raised first, the three files are
  /// opened in sequence and the first failure returns with no meshes. Malformed
  /// JSON is not a failure — `QJsonDocument::fromJson` yields an empty object
  /// there (NativePicking.cpp:223), so the manifest simply has no `meshes`
  /// array and [meshes] ends up empty.
  void prepare() {
    if (prepared) {
      return;
    }
    prepared = true;
    final String? manifestText = _readText('$root/archive-cassette.json');
    if (manifestText == null) {
      return;
    }
    final Uint8List? vertexBytes = _readBytes('$root/archive-cassette.bin');
    if (vertexBytes == null) {
      return;
    }
    final Uint8List? indexBytes = _readBytes('$root/archive-cassette-indices.bin');
    if (indexBytes == null) {
      return;
    }
    meshes
      ..clear()
      ..addAll(_buildMeshes(_jsonObject(manifestText), vertexBytes, indexBytes));
  }

  /// Drops every tree and allows a later [prepare] to reload them
  /// (NativePicking.cpp:205-209).
  void trimMemory() {
    meshes.clear();
    prepared = false;
  }

  /// Casts `origin + direction * t` against [mesh] and returns the hit point.
  ///
  /// Port of NativePicking.cpp:231-249. [prepare] runs first; an out of range
  /// [mesh], a vector that is not exactly three long or an empty tree answers
  /// with an empty map (NativePicking.cpp:234-237), and so does a miss, i.e. a
  /// non finite best (NativePicking.cpp:243-245). [side] selects the winding
  /// rule of [PickingMesh.triangle]; the Qt caller passes `2`. A hit is the
  /// map `{'x': ..., 'y': ..., 'z': ...}` of `origin + direction * best`
  /// (NativePicking.cpp:246-248).
  Map<String, double> raycast(
    int mesh,
    List<Object?> originValues,
    List<Object?> directionValues,
    int side,
  ) {
    prepare();
    if (mesh < 0 ||
        mesh >= meshes.length ||
        originValues.length != 3 ||
        directionValues.length != 3 ||
        meshes[mesh].nodes.isEmpty) {
      return const <String, double>{};
    }
    final Vec3 origin = Vec3(
      _variantDouble(originValues[0]),
      _variantDouble(originValues[1]),
      _variantDouble(originValues[2]),
    );
    final Vec3 direction = Vec3(
      _variantDouble(directionValues[0]),
      _variantDouble(directionValues[1]),
      _variantDouble(directionValues[2]),
    );
    final double best = meshes[mesh].visit(0, origin, direction, side, double.infinity);
    if (!best.isFinite) {
      return const <String, double>{};
    }
    return <String, double>{
      'x': origin.x + direction.x * best,
      'y': origin.y + direction.y * best,
      'z': origin.z + direction.z * best,
    };
  }

  // `data->meshes.resize(parts.size())` plus one `load` per part
  // (NativePicking.cpp:226-229). Non-list `meshes` behaves like Qt's empty
  // QJsonArray, non-object parts like Qt's empty QJsonObject.
  static List<PickingMesh> _buildMeshes(
    Map<String, Object?> manifest,
    Uint8List vertices,
    Uint8List indexBytes,
  ) {
    final Object? parts = manifest['meshes'];
    if (parts is! List) {
      return <PickingMesh>[];
    }
    final List<PickingMesh> built = <PickingMesh>[];
    for (final Object? part in parts) {
      built.add(
        PickingMesh.loadFromBytes(
          part: part is Map<String, Object?> ? part : const <String, Object?>{},
          vertices: vertices,
          indexBytes: indexBytes,
        ),
      );
    }
    return built;
  }
}
