/// The 5-column archive wall grid: lane/row addressing, `fileAt` /
/// `fileLocation`, card placement, and the drag-plane / tap mapping that turns
/// pointer input into a selection — a literal port of the fixed Qt sources at
/// baseline `a959ded3f98d748059d8c3eaeaa8c41f7e17b9c6`.
///
/// Sources (line numbers are from that baseline):
/// - `Qt/src/NativeScene.cpp:11-16` — `wrap()` and `nearest()`.
/// - `Qt/src/NativeScene.cpp:28-47` — `slots.json` loading and the lane bucketing
///   loop, including the `m_columns[0].isEmpty()` asset gate.
/// - `Qt/src/NativeScene.cpp:63-78` — `fileLocation`, `fileAt`, `cellPosition`.
/// - `Qt/src/NativeScene.cpp:87-164` — `select(index, navigation)` and
///   `navigate(axis, direction)`.
/// - `Qt/src/NativeScene.h:109-110` — `std::array<QVector<int>, 5> m_columns` and
///   `std::array<int, 5> m_memories{}`.
/// - `Qt/src/NativeScene.h:151,159` — `m_looping = false`, `m_selected = 0`.
/// - `Qt/src/NativeSceneInput.cpp` — implemented here: the plane walk / drag
///   track and archive drag (`:99-134`), `scenePointerMoved` (`:172`, the 7 px
///   slop), `sceneTapSelects` (`:183-185` and `:191`, the tap-versus-drag
///   predicate) and `rebase()`'s shift (`:201-210`).
/// - `Qt/src/SceneDrag.h:8-15` — `DragPosition` / `DragProjection`.
/// - `Resources/slots.json` — the `columns` / `records` payload Qt loads at
///   `NativeScene.cpp:32-33` (sha256 `e373f54b42579c5015cef8ad98d019c9290b35af8f8d9e133ff32669d3b9a331`).
///
/// Deliberately NOT ported here, because each piece has a different owner and
/// porting it twice would be a second, divergent source of truth:
/// - the ray/BVH pick itself (`NativeSceneInput.cpp:36-97`, ported in
///   `lib/scene/picking.dart`); this file only consumes a picked `SceneCell`;
/// - Qt's pointer reset (`NativeSceneInput.cpp:9-23`), the momentum seeded at
///   `:186-190` and the cursor assigned at `:22`, together with the `pointer()`
///   state machine that drives them (`:135-200`);
/// - the pixel-to-delta inversion inside `SceneDrag` (`Qt/src/SceneDrag.cpp`, outside
///   the fixed source set); this file consumes the already normalised delta that
///   `NativeSceneInput.cpp:129` reads;
/// - the wall geometry constants, which `lib/scene/scene_math.dart` already owns with the
///   same citations (`kLanePitch`, `kRowPitch`, `kRowCentre`, `kCellBaseY`,
///   `kLaneRowOrigin`);
/// - any rendering, animation, decryption or `BasicApp` wiring.
///
/// Every value below is either a Qt literal or an arithmetic fold of Qt
/// literals. Qt sites that are genuinely undefined (division by a zero period,
/// `QVector::at` out of range) are reported as Dart errors instead of being
/// given an invented mapping.
///
/// STATUS: written, deliberately NOT executed. The build/test gates for this
/// atom are NOT_RUN by contract.
library;

import 'dart:convert';
import 'dart:math' as math;

import 'package:rhine_music_database/scene/scene_math.dart'
    show Mat4, SceneCell, Vec3, kCellBaseY, kLanePitch, kLaneRowOrigin, kRowCentre, kRowPitch;

// ---------------------------------------------------------------------------
// Qt literals.
// ---------------------------------------------------------------------------

/// NativeScene.h:109-110 — both arrays are exactly five lanes wide, so every
/// lane wrap is modulo five (NativeScene.cpp:73,112,158).
const int kSceneLaneCount = 5;

/// NativeScene.cpp:89 — the selection ceiling is a hard-coded 40, independent
/// of how many records `slots.json` actually holds.
const int kSceneRecordLimit = 40;

/// NativeSceneInput.cpp:172 — a pointer only counts as moved past seven
/// logical pixels (`std::hypot(...) > 7`).
const double kSceneTapSlop = 7.0;

/// NativeSceneInput.cpp:25 — the drag plane is probed 1.85 above the actor
/// origin.
const double kSceneDragCentreHeight = 1.85;

/// NativeSceneInput.cpp:32 — the one-lane and one-row probe vectors. The lane
/// probe steps 5.2 along -x, the row probe 0.62 along -z.
const Vec3 kSceneDragLaneMotion = Vec3(-5.2, 0, 0);
const Vec3 kSceneDragRowMotion = Vec3(0, 0, -0.62);

/// NativeSceneInput.cpp:133 — the offset subtracted from the rail term before
/// the row division, i.e. the negated z of `cellPosition((2, 12))`:
/// `-((12 - 15.5) * 0.62)`. Rail 0 therefore maps to row 12 and rail 2.17 to
/// row 8.5.
const double kSceneRailRowAnchor = 2.17;

/// NativeSceneInput.cpp:133 — the lane anchor added to the camera term
/// (`m_columnCamera.value / 5.2 + 2`): camera 0 is lane 2, camera 2.0 is lane
/// 2.3846.
const double kSceneTrackLaneAnchor = 2.0;

/// NativeSceneInput.cpp:105 — a plane walk never takes more than 64 steps.
const int kScenePlaneStepCap = 64;

/// NativeSceneInput.cpp:203,206 — `rebase()` only fires past ±2048 cells.
const int kSceneRebaseLimit = 2048;

/// NativeSceneInput.cpp:204,207 — `rebase()` folds lanes by 5 and rows by 8.
const int kSceneRebaseLanePeriod = 5;
const int kSceneRebaseRowPeriod = 8;

/// NativeScene.cpp:106-107,111 — the `navigation["axis"]` literals.
const String kSceneAxisLane = 'lane';
const String kSceneAxisRow = 'row';

/// NativeScene.cpp:70 — `fileLocation()`'s fallback for an index that no
/// lane holds, and the actor's default cell (NativeScene.h:85).
const SceneCell kSceneFallbackCell = SceneCell(2, kLaneRowOrigin);

// ---------------------------------------------------------------------------
// NativeScene.cpp:11-16 — the two integer helpers every address goes through.
// ---------------------------------------------------------------------------

/// NativeScene.cpp:11-13 — `wrap()`: Euclidean wrap into `[0, count)`, and 0
/// for a non-positive count instead of dividing.
int sceneWrap(int value, int count) {
  return count > 0 ? (value % count + count) % count : 0;
}

/// NativeScene.cpp:14-16 — `nearest()`: snap `value` onto the copy of the
/// arithmetic sequence `value + k * period` that sits closest to `center`.
///
/// The `floor` is applied to `center - value + period / 2.0`, so an exact
/// half-way tie rounds towards +infinity (`sceneNearest(12, 16, 8)` is 20, not 12).
///
/// Qt divides by `period` unguarded; a non-positive period there is
/// `int(std::floor(inf))`, i.e. undefined behaviour rather than a mapping, so
/// this port raises [ArgumentError] instead of inventing a result.
int sceneNearest(int value, int center, int period) {
  if (period <= 0) {
    throw ArgumentError.value(
      period,
      'period',
      'nearest() divides by the period; Qt is undefined for a non-positive period',
    );
  }
  final double offset = (center - value + period / 2.0) / period;
  return value + offset.floor() * period;
}

// ---------------------------------------------------------------------------
// NativeSceneInput.cpp:172,183-185,191 — tap versus drag.
// ---------------------------------------------------------------------------

/// NativeSceneInput.cpp:172 — `std::hypot(x - m_down.x, y - m_down.y) > 7`.
///
/// `dart:math` has no `hypot`; the squared form is exact for these
/// magnitudes and the strict `>` keeps 7.0 itself a non-move.
bool scenePointerMoved({
  required double downX,
  required double downY,
  required double x,
  required double y,
}) {
  final double dx = x - downX;
  final double dy = y - downY;
  return math.sqrt(dx * dx + dy * dy) > kSceneTapSlop;
}

/// NativeSceneInput.cpp:183-185 and :191 — the `pointerup` branch that selects a card
/// under the pointer runs only when the pointer was captured (:183), the
/// gesture was browsing while browsing is still allowed (:184), the drag never
/// became active and the pointer never moved past [kSceneTapSlop] (:191).
///
/// [captured] is Qt's `m_captured` at the `pointerup` test itself (:183), so a
/// pointerup on an uncaptured pointer never selects, whatever the other flags
/// say.
bool sceneTapSelects({
  required bool captured,
  required bool browsing,
  required bool canBrowse,
  required bool dragActive,
  required bool moved,
}) {
  return captured && browsing && canBrowse && !dragActive && !moved;
}

// ---------------------------------------------------------------------------
// NativeSceneInput.cpp:201-230 — rebase.
// ---------------------------------------------------------------------------

/// NativeSceneInput.cpp:201-210 — the shift `rebase()` subtracts from a cell,
/// or null when Qt returns early because the shift is zero.
///
/// `|lane| > 2048` folds lanes to the nearest multiple of 5 relative to lane 2
/// (the `+ 0.5` rounds half up); `|row| > 2048` folds rows to a multiple of
/// 8 relative to row 12, with a plain `floor` and no half-up bias.
///
/// Only the shift is returned. Applying it — subtracting from `cell` and from the
/// returning actors and pulses, and moving `m_origin`, `m_laneFocus`,
/// `m_shoulder`, `m_columnCamera` and `m_rail` the other way
/// (NativeSceneInput.cpp:212-229) — belongs to whoever owns that motion state.
SceneCell? sceneRebaseShift(SceneCell cell) {
  int lane = 0;
  int row = 0;
  if (cell.lane.abs() > kSceneRebaseLimit) {
    lane = ((cell.lane - 2) / kSceneRebaseLanePeriod + 0.5).floor() * kSceneRebaseLanePeriod;
  }
  if (cell.row.abs() > kSceneRebaseLimit) {
    row = ((cell.row - kLaneRowOrigin) / kSceneRebaseRowPeriod).floor() * kSceneRebaseRowPeriod;
  }
  if (lane == 0 && row == 0) {
    return null;
  }
  return SceneCell(lane, row);
}

// ---------------------------------------------------------------------------
// Track <-> plane — NativeSceneInput.cpp:116-134.
// ---------------------------------------------------------------------------

/// The two scroll counters: `m_columnCamera.value` and `m_rail.value`
/// (NativeScene.h:118,121). Both springs start at zero, i.e. [origin].
class SceneTrack {
  const SceneTrack({required this.lane, required this.row});

  /// NativeScene.h:118,121 — `m_rail` and `m_columnCamera` are default
  /// constructed, so an untouched wall sits at lane 2, row 12.
  static const SceneTrack origin = SceneTrack(lane: 0, row: 0);

  final double lane;
  final double row;

  @override
  bool operator ==(Object other) =>
      other is SceneTrack && other.lane == lane && other.row == row;

  @override
  int get hashCode => Object.hash(lane, row);

  @override
  String toString() => 'SceneTrack($lane, $row)';
}

/// Qt `SceneMotion::DragPosition` (SceneDrag.h:8-11) — an unbounded
/// continuous lane/row coordinate, not a cell and not wrapped.
class ScenePlane {
  const ScenePlane({required this.lane, required this.row});

  final double lane;
  final double row;

  @override
  bool operator ==(Object other) =>
      other is ScenePlane && other.lane == lane && other.row == row;

  @override
  int get hashCode => Object.hash(lane, row);

  @override
  String toString() => 'ScenePlane($lane, $row)';
}

/// NativeSceneInput.cpp:133 — the inverse of the two track offsets:
/// `{lane / 5.2 + 2, (-rail - 2.17) / 0.62 + 15.5}`.
///
/// The asymmetry is Qt's: the lane counter grows with the camera, the rail
/// counter grows against the row because the row pitch is applied along -z.
ScenePlane sceneTrackPlane(SceneTrack track) => ScenePlane(
      lane: track.lane / kLanePitch + kSceneTrackLaneAnchor,
      row: (-track.row - kSceneRailRowAnchor) / kRowPitch + kRowCentre,
    );

/// NativeSceneInput.cpp:129-130 — `m_dragTrack` from the drag start track and
/// the normalised drag delta: lanes add, rows subtract.
SceneTrack sceneArchiveTrack({
  required SceneTrack start,
  required double dragLane,
  required double dragRow,
}) =>
    SceneTrack(
      lane: start.lane + dragLane * kLanePitch,
      row: start.row - dragRow * kRowPitch,
    );

/// NativeSceneInput.cpp:100 — `Cell{floor(lane + 0.5), floor(row + 0.5)}`, i.e.
/// round half up on both axes.
SceneCell scenePlaneTarget(ScenePlane plane) =>
    SceneCell((plane.lane + 0.5).floor(), (plane.row + 0.5).floor());

/// NativeSceneInput.cpp:99-114 — the cells `navigatePlane()` selects on its way
/// to `target`, in order, with consecutive duplicates dropped.
///
/// The walk is linear in the goal delta and capped at [kScenePlaneStepCap]
/// steps, so a long drag crosses at most 64 cells: the intermediate cells are
/// the interpolation at each step, and the last one is the goal itself
/// (`index == steps` reproduces `goal` exactly). An empty result means the goal
/// is the cell the actor already occupies (:102).
List<SceneCell> scenePlanePath({
  required SceneCell from,
  required ScenePlane target,
}) {
  final SceneCell goal = scenePlaneTarget(target);
  if (goal == from) {
    return const <SceneCell>[];
  }
  final int steps = math.min(
    kScenePlaneStepCap,
    math.max((goal.lane - from.lane).abs(), (goal.row - from.row).abs()),
  );
  final List<SceneCell> path = <SceneCell>[];
  SceneCell cursor = from;
  for (int index = 1; index <= steps; ++index) {
    final SceneCell cell = SceneCell(
      (from.lane + (goal.lane - from.lane) * index / steps + 0.5).floor(),
      (from.row + (goal.row - from.row) * index / steps + 0.5).floor(),
    );
    if (cell != cursor) {
      path.add(cell);
      cursor = cell;
    }
  }
  return List<SceneCell>.unmodifiable(path);
}

/// NativeSceneInput.cpp:129-133 — the `m_dragTrack` update and the
/// `navigatePlane()` call that turn a drag into selected cells, composed here.
List<SceneCell> sceneDragPath({
  required SceneTrack start,
  required double dragLane,
  required double dragRow,
  required SceneCell from,
}) {
  final SceneTrack track =
      sceneArchiveTrack(start: start, dragLane: dragLane, dragRow: dragRow);
  return scenePlanePath(from: from, target: sceneTrackPlane(track));
}

// ---------------------------------------------------------------------------
// Drag projection — NativeSceneInput.cpp:24-33.
// ---------------------------------------------------------------------------

/// One `QPointF` of `SceneMotion::DragProjection` (SceneDrag.h:12-15): the
/// screen-space step produced by one plane unit of motion.
class ScenePixelStep {
  const ScenePixelStep({required this.dx, required this.dy});

  final double dx;
  final double dy;

  @override
  bool operator ==(Object other) =>
      other is ScenePixelStep && other.dx == dx && other.dy == dy;

  @override
  int get hashCode => Object.hash(dx, dy);

  @override
  String toString() => 'ScenePixelStep($dx, $dy)';
}

/// Qt `SceneMotion::DragProjection` (SceneDrag.h:12-15): one pixel step for
/// a lane, one for a row.
class SceneDragProjection {
  const SceneDragProjection({required this.lane, required this.row});

  final ScenePixelStep lane;
  final ScenePixelStep row;

  @override
  bool operator ==(Object other) =>
      other is SceneDragProjection && other.lane == lane && other.row == row;

  @override
  int get hashCode => Object.hash(lane, row);

  @override
  String toString() => 'SceneDragProjection(lane: $lane, row: $row)';
}

/// NativeSceneInput.cpp:24-33 — `dragProjection()`.
///
/// `matrix` is Qt's `m_projection * m_view`, multiplied by the caller exactly
/// as the Qt line does. The drag plane is the point 1.85 above
/// the actor origin; each probe vector is projected at ±0.5 around it, and the
/// resulting screen delta is scaled by half the surface in pixels — `+x`
/// keeps the sign, `+y` flips it because Qt's y axis points down.
SceneDragProjection sceneDragProjection({
  required Mat4 matrix,
  required Vec3 actorPosition,
  required Vec3 actorRotation,
  required double width,
  required double height,
}) {
  final Vec3 centre = Mat4.compose(actorPosition, actorRotation)
      .point(const Vec3(0, kSceneDragCentreHeight, 0));
  ScenePixelStep project(Vec3 motion) {
    final Vec3 from = matrix.point(centre + motion * -0.5);
    final Vec3 to = matrix.point(centre + motion * 0.5);
    return ScenePixelStep(
      dx: (to.x - from.x) * width / 2,
      dy: -(to.y - from.y) * height / 2,
    );
  }

  return SceneDragProjection(
    lane: project(kSceneDragLaneMotion),
    row: project(kSceneDragRowMotion),
  );
}

// ---------------------------------------------------------------------------
// slots.json -> columns — NativeScene.cpp:28-47.
// ---------------------------------------------------------------------------

/// Sentinel for an absent JSON key, so that `"category": null` and a
/// missing `category` stay distinguishable the way `QJsonValue`'s Null
/// and Undefined are: `NativeScene.cpp:36` compares `QJsonValue`s, not
/// `QString`s, so a numeric or object category matches a column too.
class _JsonUndefined {
  const _JsonUndefined();
}

const Object _jsonUndefined = _JsonUndefined();

/// `QJsonValue::operator==` — deep equality for arrays and objects,
/// value equality otherwise, and Undefined equal to nothing but itself.
bool _jsonEquals(Object? left, Object? right) {
  if (identical(left, right)) {
    return true;
  }
  if (left is _JsonUndefined || right is _JsonUndefined) {
    return false;
  }
  if (left is Map && right is Map) {
    if (left.length != right.length) {
      return false;
    }
    for (final Object? key in left.keys) {
      if (!right.containsKey(key) || !_jsonEquals(left[key], right[key])) {
        return false;
      }
    }
    return true;
  }
  if (left is List && right is List) {
    if (left.length != right.length) {
      return false;
    }
    for (int index = 0; index < left.length; ++index) {
      if (!_jsonEquals(left[index], right[index])) {
        return false;
      }
    }
    return true;
  }
  return left == right;
}

bool _intListEquals(List<int> left, List<int> right) {
  if (left.length != right.length) {
    return false;
  }
  for (int index = 0; index < left.length; ++index) {
    if (left[index] != right[index]) {
      return false;
    }
  }
  return true;
}

/// The five record columns of the archive wall: Qt's `m_columns` plus the
/// `slots.json` payload it is built from (NativeScene.cpp:32-43).
///
/// [lanes] is always exactly [kSceneLaneCount] wide, because Qt's `m_columns` is a
/// fixed `std::array<QVector<int>, 5>` (NativeScene.h:109). [columns] is the raw
/// payload instead, so it may be shorter than five: Qt's loop stops at
/// `std::min(5, int(columns.size()))` (NativeScene.cpp:34) and leaves the
/// remaining lanes empty, which is why a short payload is accepted here rather
/// than rejected.
class SceneGrid {
  SceneGrid({
    required List<Object?> columns,
    required this.recordCount,
    required List<List<int>> lanes,
  })  : columns = List<Object?>.unmodifiable(columns),
        lanes = List<List<int>>.unmodifiable(<List<int>>[
          for (final List<int> lane in lanes) List<int>.unmodifiable(lane),
        ]) {
    if (this.columns.length > kSceneLaneCount) {
      throw ArgumentError.value(
        this.columns.length,
        'columns',
        'a payload is truncated to $kSceneLaneCount columns before it reaches the wall',
      );
    }
    if (this.lanes.length != kSceneLaneCount) {
      throw ArgumentError.value(
        this.lanes.length,
        'lanes',
        'the wall is exactly $kSceneLaneCount lanes wide',
      );
    }
  }

  /// NativeScene.cpp:32-43 — bucket every record into the column whose value
  /// equals its `category`, in file order.
  ///
  /// Qt truncates to five columns (`std::min(5, columns.size())`), ignores
  /// records that are not objects (`toObject()` on a non-object is empty),
  /// and records beyond [kSceneRecordLimit] are still bucketed — only `select`
  /// refuses them later.
  factory SceneGrid.fromJson(Object? content) {
    final Map<Object?, Object?> root =
        content is Map ? content : const <Object?, Object?>{};
    final Object? rawColumns = root['columns'];
    final Object? rawRecords = root['records'];
    final List<Object?> columnValues =
        rawColumns is List ? rawColumns : const <Object?>[];
    final List<Object?> recordValues =
        rawRecords is List ? rawRecords : const <Object?>[];
    final int laneWidth = math.min(kSceneLaneCount, columnValues.length);
    final List<List<int>> lanes = <List<int>>[
      for (int lane = 0; lane < kSceneLaneCount; ++lane) <int>[],
    ];
    for (int lane = 0; lane < laneWidth; ++lane) {
      final Object? category = columnValues[lane];
      for (int index = 0; index < recordValues.length; ++index) {
        final Object? record = recordValues[index];
        final Object? value = record is Map
            ? (record.containsKey('category')
                ? record['category']
                : _jsonUndefined)
            : _jsonUndefined;
        if (_jsonEquals(value, category)) {
          lanes[lane].add(index);
        }
      }
    }
    return SceneGrid(
      columns: columnValues.sublist(0, laneWidth),
      recordCount: recordValues.length,
      lanes: lanes,
    );
  }

  /// NativeScene.cpp:19-25 — `read()` parses the file, and a parse failure
  /// is an empty object: a wall with no records rather than an exception.
  factory SceneGrid.fromSlotsJson(String text) {
    Object? decoded;
    try {
      decoded = jsonDecode(text);
    } on FormatException {
      decoded = null;
    }
    return SceneGrid.fromJson(decoded);
  }

  /// The raw `columns` values, truncated to [kSceneLaneCount], in file
  /// order — lane 0 is `搜索结果` for the shipped payload.
  final List<Object?> columns;

  /// `records.size()` (NativeScene.cpp:35). Informational: neither
  /// `fileAt` nor `fileLocation` reads it, and `select` is capped at
  /// [kSceneRecordLimit] instead.
  final int recordCount;

  /// Record indices per lane, ascending — Qt's `m_columns`
  /// (NativeScene.cpp:34-43). Every lane list exists even when empty.
  final List<List<int>> lanes;

  /// NativeScene.cpp:40-42 — each lane's first record, 0 for an empty lane
  /// (`std::array<int, 5> m_memories{}`, NativeScene.h:110).
  List<int> get memories => List<int>.unmodifiable(<int>[
        for (final List<int> lane in lanes) lane.isEmpty ? 0 : lane.first,
      ]);

  /// The `slots.json` half of NativeScene.cpp:44-47's asset gate
  /// (`m_columns[0].isEmpty()`). The `actorTemplate` half belongs to the
  /// appearance atom, so this only reports whether lane 0 has records.
  bool get isUsable => lanes[0].isNotEmpty;

  /// NativeScene.cpp:76-78 — the canonical card position: lane pitch around
  /// lane 2, base height -4.6, row pitch around row 15.5.
  ///
  /// Written out here rather than delegating to `scene_math`'s
  /// `cellPosition` so the two transcriptions can be compared in tests.
  Vec3 cellPosition(SceneCell cell) => Vec3(
        (cell.lane - 2) * kLanePitch,
        kCellBaseY,
        (cell.row - kRowCentre) * kRowPitch,
      );

  /// NativeScene.cpp:63-71 — where record `index` sits: on row
  /// `12 + position` of the first lane whose column holds it, and
  /// [kSceneFallbackCell] when no column holds it.
  SceneCell fileLocation(int index) {
    for (int lane = 0; lane < kSceneLaneCount; ++lane) {
      final int row = lanes[lane].indexOf(index);
      if (row >= 0) {
        return SceneCell(lane, kLaneRowOrigin + row);
      }
    }
    return kSceneFallbackCell;
  }

  /// NativeScene.cpp:72-75 — the record addressable at `cell`, with lane and
  /// row wrapped independently of the cell's absolute value.
  ///
  /// `QVector::value` yields `int()` past the end, so an empty lane reads
  /// as record 0 instead of raising. That is unreachable with the shipped 5x8
  /// payload and only shows up on a synthetic grid.
  int fileAt(SceneCell cell) {
    final List<int> files = lanes[sceneWrap(cell.lane, kSceneLaneCount)];
    if (files.isEmpty) {
      return 0;
    }
    return files[sceneWrap(cell.row - kLaneRowOrigin, files.length)];
  }

  @override
  String toString() => 'SceneGrid(columns: $columns, recordCount: $recordCount, '
      'lanes: $lanes)';
}

// ---------------------------------------------------------------------------
// Selection — NativeScene.cpp:87-164.
// ---------------------------------------------------------------------------

/// The selection state `select` and `navigate` write: Qt's `m_selected`
/// (NativeScene.h:159), `m_actor.cell` and `m_memories` (NativeScene.h:110).
///
/// Immutable on purpose: `select` returns a new value, so the pointer, momentum
/// and animation state that Qt resets inside the same function can live with
/// whoever owns them without the mapping here mutating anything shared.
class SceneSelection {
  SceneSelection({
    required this.selected,
    required this.cell,
    required List<int> laneMemory,
  }) : laneMemory = List<int>.unmodifiable(laneMemory) {
    if (this.laneMemory.length != kSceneLaneCount) {
      throw ArgumentError.value(
        this.laneMemory.length,
        'laneMemory',
        'the wall is exactly $kSceneLaneCount lanes wide',
      );
    }
  }

  /// NativeScene.cpp:40-54 — `m_selected = 0` (NativeScene.h:159), the actor's
  /// default cell (2, 12) (NativeScene.h:85), `m_memories` seeded with each
  /// lane's first record, then `select(0)` while `m_looping` is still
  /// false (NativeScene.h:151), so the cell snaps to record 0's canonical cell.
  factory SceneSelection.initial(SceneGrid grid) => SceneSelection(
        selected: 0,
        cell: const SceneCell(2, kLaneRowOrigin),
        laneMemory: grid.memories,
      ).select(grid, 0, looping: false);

  /// The selected record index, Qt's `m_selected`.
  final int selected;

  /// The selected card's cell, Qt's `m_actor.cell`. Unbounded: it can be
  /// lane 5 or row -3, and only `fileAt` wraps.
  final SceneCell cell;

  /// Per-lane last selection, Qt's `m_memories` — indexed by the
  /// *canonical* lane of the selected record, never by `cell.lane`.
  final List<int> laneMemory;

  /// NativeScene.cpp:87-154 — `select(index, navigation)`.
  ///
  /// The three `navigation` keys map to [cell] (`"cell"`, present only
  /// for a tap or plane step), [axis] (`"axis"`) and [direction]
  /// (`"direction"`). [looping] is Qt's `m_looping` (NativeScene.h:151,
  /// `mode != "boot"` at NativeScene.cpp:180), and it is required: in Qt the
  /// flag is member state set by the caller's mode, so a default here would
  /// silently give every caller one of the two branches — boot-time selection
  /// keeps the canonical cell (NativeScene.cpp:53 and :272-273 simply select,
  /// leaving the `NativeScene.h:151` initializer's false in place) while a live
  /// selection resolves the neighbour (every other caller passes true).
  ///
  /// Out-of-range indices are ignored (:89) and return this instance unchanged.
  /// A canonical lane with no records, reached without an explicit cell, is
  /// undefined in Qt: `select` binds `files = m_columns[canonical.lane]`
  /// (:104) and then calls `nearest(canonical.row, m_actor.cell.row,
  /// files.size())` (:105), whose zero period divides by zero inside
  /// `nearest` (:15). It raises [ArgumentError] here.
  ///
  /// Not modelled because they are motion/decryption state, not mapping: the
  /// pointer reset (:92-94), the returning-actor adoption (:143-151),
  /// `pulse(cell)` (:152) and `m_targetRotation = 0` (:153).
  SceneSelection select(
    SceneGrid grid,
    int index, {
    SceneCell? cell,
    String? axis,
    int direction = 0,
    required bool looping,
  }) {
    if (index < 0 || index >= kSceneRecordLimit) {
      return this;
    }
    final SceneCell canonical = grid.fileLocation(index);
    SceneCell target = canonical;
    if (looping) {
      if (cell != null) {
        target = cell;
      } else {
        final List<int> files = grid.lanes[canonical.lane];
        int lane = canonical.lane;
        int row = sceneNearest(canonical.row, this.cell.row, files.length);
        if (axis == kSceneAxisRow) {
          lane = this.cell.lane;
          row = this.cell.row + direction;
        } else if (axis == kSceneAxisLane) {
          lane = this.cell.lane + direction;
        } else {
          lane = sceneNearest(canonical.lane, this.cell.lane, kSceneLaneCount);
        }
        target = SceneCell(lane, row);
      }
    }
    final List<int> memory = List<int>.of(laneMemory);
    memory[canonical.lane] = index;
    return SceneSelection(selected: index, cell: target, laneMemory: memory);
  }

  /// NativeScene.cpp:155-164 — `navigate(axis, direction)`.
  ///
  /// A lane step jumps to the lane memory around the selected record's
  /// *canonical* lane; any other axis falls into the row branch, which walks
  /// the canonical lane's records with [sceneWrap].
  ///
  /// Both branches delegate with `looping: true`. Qt's `navigate` reads the
  /// member flag, and its only caller is the library/HUD navigation request
  /// (`NativeApplication.cpp:38-39`), emitted from `MusicDirectory.cpp:78,201`
  /// and `MusicSiren.cpp:238` — each right after `modeRequested("archive")` —
  /// and from `MusicLibrary.cpp:665`; those are archive-mode requests, so the
  /// flag is true when `navigate` runs. Future UI wiring must put the scene in
  /// archive/detail mode before calling this. The pointer path never calls
  /// `navigate`: it selects directly (`NativeSceneInput.cpp:111`, `:194`), and
  /// `canBrowse()` (`:6-8`) gates only the pointer handlers (`:148`, `:156`,
  /// `:174`, `:184`).
  ///
  /// Returns null where Qt is undefined — `QVector::at` on a lane with no
  /// records (:162).
  SceneSelection? navigate(
    SceneGrid grid, {
    required String axis,
    required int direction,
  }) {
    final SceneCell location = grid.fileLocation(selected);
    if (axis == kSceneAxisLane) {
      final int index =
          laneMemory[sceneWrap(location.lane + direction, kSceneLaneCount)];
      return select(grid, index, looping: true, axis: kSceneAxisLane, direction: direction);
    }
    final List<int> files = grid.lanes[location.lane];
    if (files.isEmpty) {
      return null;
    }
    final int position = files.indexOf(selected);
    final int index = sceneWrap(position + direction, files.length);
    return select(grid, files[index], looping: true, axis: kSceneAxisRow, direction: direction);
  }

  @override
  bool operator ==(Object other) =>
      other is SceneSelection &&
      other.selected == selected &&
      other.cell == cell &&
      _intListEquals(other.laneMemory, laneMemory);

  @override
  int get hashCode => Object.hash(selected, cell, Object.hashAll(laneMemory));

  @override
  String toString() => 'SceneSelection(selected: $selected, cell: $cell, '
      'laneMemory: $laneMemory)';
}

