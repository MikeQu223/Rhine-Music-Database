/// Unit tests for the archive wall grid in `lib/basic/scene_grid.dart` — the
/// lane/row addressing, `fileAt` / `fileLocation`, card placement and the
/// drag-plane / tap mapping transcribed from the fixed Qt sources at baseline
/// `a959ded3f98d748059d8c3eaeaa8c41f7e17b9c6`.
///
/// Sources cited per test: `Qt/src/NativeScene.cpp:11-16` (`wrap`, `nearest`),
/// `:28-47` (the `slots.json` bucketing loop), `:63-78` (`fileLocation`,
/// `fileAt`, `cellPosition`), `:87-164` (`select`, `navigate`),
/// `Qt/src/NativeSceneInput.cpp:99-134` (plane walk, drag track),
/// `:172,183-196` (tap slop and the tap branch), `:201-210` (`rebase`),
/// `Qt/src/SceneDrag.h:8-15` (`DragPosition` / `DragProjection`).
///
/// [kSlotsJson] is the shipped `Resources/slots.json` pasted verbatim (sha256
/// `e373f54b42579c5015cef8ad98d019c9290b35af8f8d9e133ff32669d3b9a331`), so the lane
/// tables below are measured against the real asset instead of a hand-written
/// fixture that could silently drift from it.
///
/// STATUS: written, deliberately NOT executed. The build/test gates for this atom
/// are NOT_RUN by contract; `flutter test` was never run against this file.
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:rhine_music_database/basic/scene_grid.dart';
import 'package:rhine_music_database/scene/scene_math.dart'
    show Mat4, SceneCell, Vec3, cellPosition, kLanePitch, kLaneRowOrigin, kRowPitch;

/// `Resources/slots.json`, byte for byte.
const String kSlotsJson = r'''
{
    "columns": ["搜索结果", "喜欢的歌曲", "我的歌单", "收藏歌单", "收藏专辑"],
    "categories": [
        "搜索结果",
        "喜欢的歌曲",
        "我的歌单",
        "收藏歌单",
        "收藏专辑"
    ],
    "records": [
        {
            "id": "SLOT-3-1",
            "title": "音乐槽位",
            "category": "我的歌单"
        },
        {
            "id": "SLOT-1-1",
            "title": "音乐槽位",
            "category": "搜索结果"
        },
        {
            "id": "SLOT-2-1",
            "title": "音乐槽位",
            "category": "喜欢的歌曲"
        },
        {
            "id": "SLOT-4-1",
            "title": "音乐槽位",
            "category": "收藏歌单"
        },
        {
            "id": "SLOT-2-2",
            "title": "音乐槽位",
            "category": "喜欢的歌曲"
        },
        {
            "id": "SLOT-3-2",
            "title": "音乐槽位",
            "category": "我的歌单"
        },
        {
            "id": "SLOT-1-2",
            "title": "音乐槽位",
            "category": "搜索结果"
        },
        {
            "id": "SLOT-5-1",
            "title": "音乐槽位",
            "category": "收藏专辑"
        },
        {
            "id": "SLOT-1-3",
            "title": "音乐槽位",
            "category": "搜索结果"
        },
        {
            "id": "SLOT-2-3",
            "title": "音乐槽位",
            "category": "喜欢的歌曲"
        },
        {
            "id": "SLOT-1-4",
            "title": "音乐槽位",
            "category": "搜索结果"
        },
        {
            "id": "SLOT-5-2",
            "title": "音乐槽位",
            "category": "收藏专辑"
        },
        {
            "id": "SLOT-3-3",
            "title": "音乐槽位",
            "category": "我的歌单"
        },
        {
            "id": "SLOT-3-4",
            "title": "音乐槽位",
            "category": "我的歌单"
        },
        {
            "id": "SLOT-3-5",
            "title": "音乐槽位",
            "category": "我的歌单"
        },
        {
            "id": "SLOT-3-6",
            "title": "音乐槽位",
            "category": "我的歌单"
        },
        {
            "id": "SLOT-3-7",
            "title": "音乐槽位",
            "category": "我的歌单"
        },
        {
            "id": "SLOT-3-8",
            "title": "音乐槽位",
            "category": "我的歌单"
        },
        {
            "id": "SLOT-1-5",
            "title": "音乐槽位",
            "category": "搜索结果"
        },
        {
            "id": "SLOT-1-6",
            "title": "音乐槽位",
            "category": "搜索结果"
        },
        {
            "id": "SLOT-1-7",
            "title": "音乐槽位",
            "category": "搜索结果"
        },
        {
            "id": "SLOT-1-8",
            "title": "音乐槽位",
            "category": "搜索结果"
        },
        {
            "id": "SLOT-2-4",
            "title": "音乐槽位",
            "category": "喜欢的歌曲"
        },
        {
            "id": "SLOT-2-5",
            "title": "音乐槽位",
            "category": "喜欢的歌曲"
        },
        {
            "id": "SLOT-2-6",
            "title": "音乐槽位",
            "category": "喜欢的歌曲"
        },
        {
            "id": "SLOT-2-7",
            "title": "音乐槽位",
            "category": "喜欢的歌曲"
        },
        {
            "id": "SLOT-2-8",
            "title": "音乐槽位",
            "category": "喜欢的歌曲"
        },
        {
            "id": "SLOT-4-2",
            "title": "音乐槽位",
            "category": "收藏歌单"
        },
        {
            "id": "SLOT-4-3",
            "title": "音乐槽位",
            "category": "收藏歌单"
        },
        {
            "id": "SLOT-4-4",
            "title": "音乐槽位",
            "category": "收藏歌单"
        },
        {
            "id": "SLOT-4-5",
            "title": "音乐槽位",
            "category": "收藏歌单"
        },
        {
            "id": "SLOT-4-6",
            "title": "音乐槽位",
            "category": "收藏歌单"
        },
        {
            "id": "SLOT-4-7",
            "title": "音乐槽位",
            "category": "收藏歌单"
        },
        {
            "id": "SLOT-4-8",
            "title": "音乐槽位",
            "category": "收藏歌单"
        },
        {
            "id": "SLOT-5-3",
            "title": "音乐槽位",
            "category": "收藏专辑"
        },
        {
            "id": "SLOT-5-4",
            "title": "音乐槽位",
            "category": "收藏专辑"
        },
        {
            "id": "SLOT-5-5",
            "title": "音乐槽位",
            "category": "收藏专辑"
        },
        {
            "id": "SLOT-5-6",
            "title": "音乐槽位",
            "category": "收藏专辑"
        },
        {
            "id": "SLOT-5-7",
            "title": "音乐槽位",
            "category": "收藏专辑"
        },
        {
            "id": "SLOT-5-8",
            "title": "音乐槽位",
            "category": "收藏专辑"
        }
    ]
}''';

/// NativeScene.cpp:32-43 applied to [kSlotsJson]: 5 columns, 40 records, 8 per lane.
SceneGrid realGrid() => SceneGrid.fromSlotsJson(kSlotsJson);

void expectCell(SceneCell actual, int lane, int row, {String? reason}) {
  expect(actual.lane, lane, reason: reason);
  expect(actual.row, row, reason: reason);
}

/// Compares cells as `lane:row` keys so a failure prints the address, not an object.
void expectPath(List<SceneCell> actual, List<List<int>> expected) {
  expect(
    <String>[for (final SceneCell cell in actual) cell.key],
    <String>[for (final List<int> cell in expected) '${cell[0]}:${cell[1]}'],
  );
}

void main() {
  group('sceneWrap — NativeScene.cpp:11-13', () {
    test('wraps negatives and overshoots into the lane range', () {
      expect(sceneWrap(-1, 5), 4);
      expect(sceneWrap(-6, 5), 4);
      expect(sceneWrap(5, 5), 0);
      expect(sceneWrap(7, 5), 2);
      expect(sceneWrap(0, 5), 0);
    });

    test('returns 0 for a non-positive count instead of dividing', () {
      expect(sceneWrap(3, 0), 0);
      expect(sceneWrap(-3, 0), 0);
      expect(sceneWrap(3, -1), 0);
    });
  });

  group('sceneNearest — NativeScene.cpp:14-16', () {
    test('snaps onto the copy of the period sequence closest to the centre', () {
      expect(sceneNearest(12, 12, 8), 12);
      expect(sceneNearest(12, 19, 8), 20);
      expect(sceneNearest(12, 11, 8), 12);
      expect(sceneNearest(12, 9, 8), 12);
    });

    test('an exact half-way tie rounds towards +infinity', () {
      // floor((16 - 12 + 4) / 8) == floor(1.0); the other copy is 4 away, 20 is 4 away.
      expect(sceneNearest(12, 16, 8), 20);
      expect(sceneNearest(12, 8, 8), 12);
    });

    test('lane copies are unbounded, so a canonical lane can snap below zero', () {
      // canonical lane 4 nearest lane 1 is -1, not 4: the wall is infinite.
      expect(sceneNearest(4, 1, 5), -1);
      expect(sceneNearest(0, 2, 5), 0);
      expect(sceneNearest(0, 12, 5), 10);
    });

    test('raises instead of inventing a mapping for a non-positive period', () {
      expect(() => sceneNearest(12, 12, 0), throwsArgumentError);
      expect(() => sceneNearest(12, 12, -1), throwsArgumentError);
    });
  });

  group('SceneGrid.fromSlotsJson — the shipped Resources/slots.json', () {
    final SceneGrid grid = realGrid();

    test('reads the five columns in file order', () {
      expect(grid.columns, <Object?>['搜索结果', '喜欢的歌曲', '我的歌单', '收藏歌单', '收藏专辑']);
      expect(grid.columns.length, kSceneLaneCount);
      expect(grid.recordCount, 40);
    });

    test('buckets records into lanes by category, keeping file order', () {
      expect(grid.lanes[0], <int>[1, 6, 8, 10, 18, 19, 20, 21]);
      expect(grid.lanes[1], <int>[2, 4, 9, 22, 23, 24, 25, 26]);
      expect(grid.lanes[2], <int>[0, 5, 12, 13, 14, 15, 16, 17]);
      expect(grid.lanes[3], <int>[3, 27, 28, 29, 30, 31, 32, 33]);
      expect(grid.lanes[4], <int>[7, 11, 34, 35, 36, 37, 38, 39]);
      expect(grid.lanes.map((List<int> lane) => lane.length).toList(), <int>[8, 8, 8, 8, 8]);
    });

    test('seeds each lane memory with the first record of that lane', () {
      expect(grid.memories, <int>[1, 2, 0, 3, 7]);
    });

    test('is usable because lane 0 has records (NativeScene.cpp:44-47)', () {
      expect(grid.isUsable, isTrue);
    });

    test('the record ids encode fileLocation as SLOT-<lane+1>-<row+1>', () {
      final Map<String, Object?> root = jsonDecode(kSlotsJson) as Map<String, Object?>;
      final List<Object?> records = root['records']! as List<Object?>;
      expect(records, hasLength(40));
      for (int index = 0; index < records.length; ++index) {
        final Map<Object?, Object?> record = records[index]! as Map<Object?, Object?>;
        final SceneCell location = grid.fileLocation(index);
        expect(
          record['id'],
          'SLOT-${location.lane + 1}-${location.row - kLaneRowOrigin + 1}',
          reason: 'record $index',
        );
        expect(record['category'], grid.columns[location.lane], reason: 'record $index');
      }
    });

    test('fileLocation returns the first lane whose column holds the record', () {
      expectCell(grid.fileLocation(0), 2, 12);
      expectCell(grid.fileLocation(1), 0, 12);
      expectCell(grid.fileLocation(2), 1, 12);
      expectCell(grid.fileLocation(3), 3, 12);
      expectCell(grid.fileLocation(4), 1, 13);
      expectCell(grid.fileLocation(5), 2, 13);
      expectCell(grid.fileLocation(7), 4, 12);
      expectCell(grid.fileLocation(10), 0, 15);
      expectCell(grid.fileLocation(39), 4, 19);
    });

    test('fileLocation falls back to (2, 12) for an index no lane holds', () {
      expectCell(grid.fileLocation(40), 2, 12);
      expectCell(grid.fileLocation(-1), 2, 12);
      expectCell(grid.fileLocation(1000), 2, 12);
    });

    test('fileAt wraps the lane modulo 5 and the row modulo the lane length', () {
      expect(grid.fileAt(const SceneCell(2, 12)), 0);
      expect(grid.fileAt(const SceneCell(0, 12)), 1);
      expect(grid.fileAt(const SceneCell(4, 19)), 39);
      // lane 7 is the same column as lane 2; lane 5 the same as lane 0.
      expect(grid.fileAt(const SceneCell(7, 12)), 0);
      expect(grid.fileAt(const SceneCell(5, 12)), 1);
      // row 20 is row 12 again; row 11 is the last row of the lane.
      expect(grid.fileAt(const SceneCell(2, 20)), 0);
      expect(grid.fileAt(const SceneCell(2, 11)), 17);
      expect(grid.fileAt(const SceneCell(-3, 19)), 17);
      expect(grid.fileAt(const SceneCell(7, 15)), 13);
    });

    test('fileAt and fileLocation round-trip every record', () {
      for (int index = 0; index < 40; ++index) {
        expect(grid.fileAt(grid.fileLocation(index)), index, reason: 'record $index');
      }
    });

    test('cellPosition is the literal ((lane-2)*5.2, -4.6, (row-15.5)*0.62)', () {
      final Vec3 centre = grid.cellPosition(const SceneCell(2, 12));
      expect(centre.x, 0.0); // (2 - 2) * 5.2 is exactly zero
      expect(centre.y, -4.6);
      expect(centre.z, closeTo(-2.17, 1e-12));

      final Vec3 corner = grid.cellPosition(const SceneCell(-1, 20));
      expect(corner.x, closeTo(-15.6, 1e-9));
      expect(corner.y, -4.6);
      expect(corner.z, closeTo(2.79, 1e-9));

      final Vec3 far = grid.cellPosition(const SceneCell(4, -3));
      expect(far.x, closeTo(10.4, 1e-9));
      expect(far.z, closeTo(-11.47, 1e-9));
    });

    test('cellPosition agrees exactly with scene_math.cellPosition', () {
      const List<SceneCell> cells = <SceneCell>[
        SceneCell(2, 12),
        SceneCell(0, 12),
        SceneCell(4, 19),
        SceneCell(-3, 20),
      ];
      for (final SceneCell cell in cells) {
        expect(grid.cellPosition(cell), cellPosition(cell), reason: cell.key);
      }
    });
  });

  group('SceneGrid.fromJson — the Qt bucketing edge cases', () {
    test('truncates the payload to five columns (std::min(5, columns.size()))', () {
      final SceneGrid grid = SceneGrid.fromJson(<String, Object?>{
        'columns': <Object?>['a', 'b', 'c', 'd', 'e', 'f'],
        'records': <Object?>[
          <String, Object?>{'category': 'a'},
          <String, Object?>{'category': 'f'},
          <String, Object?>{'category': 'e'},
        ],
      });
      expect(grid.columns, <Object?>['a', 'b', 'c', 'd', 'e']);
      expect(grid.lanes[0], <int>[0]);
      expect(grid.lanes[4], <int>[2]);
      expect(grid.recordCount, 3);
    });

    test('leaves the lanes past a short payload empty, exactly as Qt does', () {
      final SceneGrid grid = SceneGrid.fromJson(<String, Object?>{
        'columns': <Object?>['a', 'b'],
        'records': <Object?>[
          <String, Object?>{'category': 'a'},
          <String, Object?>{'category': 'b'},
        ],
      });
      expect(grid.columns, <Object?>['a', 'b']);
      expect(grid.lanes[2], isEmpty);
      expect(grid.lanes[4], isEmpty);
      expect(grid.memories, <int>[0, 1, 0, 0, 0]);
      expect(grid.isUsable, isTrue);
    });

    test('ignores records that are not objects (toObject() is empty)', () {
      final SceneGrid grid = SceneGrid.fromJson(<String, Object?>{
        'columns': <Object?>['a', 'b', 'c', 'd', 'e'],
        'records': <Object?>[
          42,
          'a',
          null,
          <Object?>[],
          <String, Object?>{'category': 'a'},
        ],
      });
      expect(grid.recordCount, 5);
      expect(grid.lanes[0], <int>[4]);
    });

    test('matches an explicit null category but not a missing one', () {
      final SceneGrid nullColumn = SceneGrid.fromJson(<String, Object?>{
        'columns': <Object?>[null, 'b', 'c', 'd', 'e'],
        'records': <Object?>[
          <String, Object?>{'category': null},
          <Object?>[],
          <String, Object?>{'category': 'b'},
        ],
      });
      expect(nullColumn.lanes[0], <int>[0]);
      expect(nullColumn.lanes[1], <int>[2]);

      final SceneGrid missingCategory = SceneGrid.fromJson(<String, Object?>{
        'columns': <Object?>[null, 'b', 'c', 'd', 'e'],
        'records': <Object?>[<String, Object?>{}],
      });
      expect(missingCategory.lanes[0], isEmpty);
    });

    test('compares categories like QJsonValue, not like strings', () {
      final SceneGrid grid = SceneGrid.fromJson(<String, Object?>{
        'columns': <Object?>[1, 'b', 'c', 'd', 'e'],
        'records': <Object?>[
          <String, Object?>{'category': 1},
          <String, Object?>{'category': 1.0},
          <String, Object?>{'category': '1'},
        ],
      });
      expect(grid.lanes[0], <int>[0, 1]);
    });

    test('a parse failure is an empty wall, not an exception (NativeScene.cpp:19-25)', () {
      final SceneGrid grid = SceneGrid.fromSlotsJson('{not json');
      expect(grid.columns, isEmpty);
      expect(grid.lanes, <List<int>>[<int>[], <int>[], <int>[], <int>[], <int>[]]);
      expect(grid.recordCount, 0);
      expect(grid.memories, <int>[0, 0, 0, 0, 0]);
      expect(grid.isUsable, isFalse);
      expectCell(grid.fileLocation(0), 2, 12);
    });

    test('non-object and non-list payloads are empty walls', () {
      expect(SceneGrid.fromJson(null).lanes[0], isEmpty);
      expect(SceneGrid.fromJson(<Object?>[]).recordCount, 0);
      expect(
        SceneGrid.fromJson(<String, Object?>{'columns': 'nope', 'records': 7}).recordCount,
        0,
      );
    });

    test('rejects a lane array that is not five wide', () {
      expect(
        () => SceneGrid(
          columns: <Object?>['a', 'b', 'c', 'd', 'e'],
          recordCount: 0,
          lanes: <List<int>>[<int>[], <int>[]],
        ),
        throwsArgumentError,
      );
      expect(
        () => SceneGrid(
          columns: <Object?>['a', 'b', 'c', 'd', 'e'],
          recordCount: 0,
          lanes: <List<int>>[<int>[], <int>[], <int>[], <int>[], <int>[], <int>[]],
        ),
        throwsArgumentError,
      );
    });

    test('rejects a payload wider than five columns', () {
      expect(
        () => SceneGrid(
          columns: <Object?>['a', 'b', 'c', 'd', 'e', 'f'],
          recordCount: 0,
          lanes: <List<int>>[<int>[], <int>[], <int>[], <int>[], <int>[]],
        ),
        throwsArgumentError,
      );
    });
  });

  group('SceneSelection.initial — NativeScene.cpp:28-55', () {
    test('starts on record 0 at the canonical cell of record 0', () {
      final SceneGrid grid = realGrid();
      final SceneSelection selection = SceneSelection.initial(grid);
      expect(selection.selected, 0);
      expectCell(selection.cell, 2, 12);
      expect(selection.laneMemory, <int>[1, 2, 0, 3, 7]);
      expect(selection.laneMemory, grid.memories);
    });

    test('an empty lane contributes memory 0', () {
      final SceneGrid sparse = SceneGrid(
        columns: <Object?>['a', 'b', 'c', 'd', 'e'],
        recordCount: 1,
        lanes: <List<int>>[<int>[0], <int>[], <int>[], <int>[], <int>[]],
      );
      expect(SceneSelection.initial(sparse).laneMemory, <int>[0, 0, 0, 0, 0]);
    });
  });

  group('SceneSelection.navigate — NativeScene.cpp:155-164', () {
    final SceneGrid grid = realGrid();

    test('a lane step walks the lane memories around the canonical lane', () {
      final SceneSelection first = SceneSelection.initial(grid)
          .navigate(grid, axis: kSceneAxisLane, direction: 1)!;
      expect(first.selected, 3);
      expectCell(first.cell, 3, 12);
      expect(first.laneMemory, <int>[1, 2, 0, 3, 7]);

      final SceneSelection second =
          first.navigate(grid, axis: kSceneAxisLane, direction: 1)!;
      expect(second.selected, 7);
      expectCell(second.cell, 4, 12);

      // Lane 5 is past the last lane: the cell lane keeps growing while fileAt wraps.
      final SceneSelection third =
          second.navigate(grid, axis: kSceneAxisLane, direction: 1)!;
      expect(third.selected, 1);
      expectCell(third.cell, 5, 12);
      expect(grid.fileAt(third.cell), 1);

      final SceneSelection back =
          third.navigate(grid, axis: kSceneAxisLane, direction: -1)!;
      expect(back.selected, 7);
      expectCell(back.cell, 4, 12);
    });

    test('lane -1 from the start lands on the first lane', () {
      final SceneSelection selection = SceneSelection.initial(grid)
          .navigate(grid, axis: kSceneAxisLane, direction: -1)!;
      expect(selection.selected, 2);
      expectCell(selection.cell, 1, 12);
      expect(selection.laneMemory, <int>[1, 2, 0, 3, 7]);
    });

    test('a row step walks the canonical lane and wraps at its ends', () {
      final SceneSelection next =
          SceneSelection.initial(grid).navigate(grid, axis: kSceneAxisRow, direction: 1)!;
      expect(next.selected, 5);
      expectCell(next.cell, 2, 13);
      expect(next.laneMemory, <int>[1, 2, 5, 3, 7]);

      final SceneSelection previous = SceneSelection.initial(grid)
          .navigate(grid, axis: kSceneAxisRow, direction: -1)!;
      expect(previous.selected, 17);
      expectCell(previous.cell, 2, 11);
      expect(previous.laneMemory, <int>[1, 2, 17, 3, 7]);
    });

    test('every axis except "lane" takes the row branch', () {
      final SceneSelection selection = SceneSelection.initial(grid)
          .navigate(grid, axis: 'row-ish', direction: 1)!;
      expect(selection.selected, 5);
      expectCell(selection.cell, 2, 13);
    });

    test('returns null where Qt reads past the end of an empty lane', () {
      final SceneGrid sparse = SceneGrid(
        columns: <Object?>['a', 'b', 'c', 'd', 'e'],
        recordCount: 1,
        lanes: <List<int>>[<int>[0], <int>[], <int>[], <int>[], <int>[]],
      );
      final SceneSelection selection = SceneSelection.initial(sparse).select(
        sparse,
        39,
        cell: const SceneCell(3, 12),
        looping: true,
      );
      expect(selection.selected, 39);
      // Record 39 lives in lane 2, which has no records in this synthetic wall.
      expect(selection.navigate(sparse, axis: kSceneAxisRow, direction: 1), isNull);
    });
  });

  group('SceneSelection.select — NativeScene.cpp:87-154', () {
    final SceneGrid grid = realGrid();

    test('ignores indices outside [0, 40) and returns the same instance', () {
      final SceneSelection selection = SceneSelection.initial(grid);
      expect(identical(selection.select(grid, 40, looping: true), selection), isTrue);
      expect(identical(selection.select(grid, -1, looping: true), selection), isTrue);
      expect(selection.select(grid, 40, looping: true).selected, 0);
    });

    test('an explicit cell is kept literally while memory follows the canonical lane', () {
      final SceneSelection selection = SceneSelection.initial(grid).select(
        grid,
        13,
        cell: const SceneCell(7, 15),
        looping: true,
      );
      expect(selection.selected, 13);
      expectCell(selection.cell, 7, 15);
      // Record 13's canonical cell is (2, 15): the memory slot is lane 2, not lane 7.
      expect(selection.laneMemory[2], 13);
      expect(selection.laneMemory[3], 3);
    });

    test('boot mode ignores the explicit cell and snaps to the canonical cell', () {
      final SceneSelection selection = SceneSelection.initial(grid).select(
        grid,
        13,
        cell: const SceneCell(7, 15),
        looping: false,
      );
      expect(selection.selected, 13);
      expectCell(selection.cell, 2, 15);
      expect(selection.laneMemory[2], 13);
    });

    test('without an explicit cell both axes snap to the copies nearest the actor', () {
      final SceneSelection far = SceneSelection.initial(grid).select(
        grid,
        0,
        cell: const SceneCell(2, 20),
        looping: true,
      );
      expectCell(far.cell, 2, 20);

      // Record 4's canonical cell is (1, 13): nearest(13, 20, 8) is 21, nearest(1, 2, 5) is 1.
      final SceneSelection snapped = far.select(grid, 4, looping: true);
      expect(snapped.selected, 4);
      expectCell(snapped.cell, 1, 21);
      expect(grid.fileAt(snapped.cell), 4);
    });

    test('raises where Qt would index into an empty lane', () {
      final SceneGrid sparse = SceneGrid(
        columns: <Object?>['a', 'b', 'c', 'd', 'e'],
        recordCount: 1,
        lanes: <List<int>>[<int>[0], <int>[], <int>[], <int>[], <int>[]],
      );
      expect(
        () => SceneSelection.initial(sparse).select(sparse, 39, looping: true),
        throwsArgumentError,
      );
    });

    test('laneMemory must be five wide', () {
      expect(
        () => SceneSelection(
          selected: 0,
          cell: const SceneCell(2, 12),
          laneMemory: <int>[0],
        ),
        throwsArgumentError,
      );
    });

    test('two selections with the same state are equal', () {
      final SceneSelection first = SceneSelection.initial(grid);
      final SceneSelection second = first.select(grid, 0, looping: true);
      expect(second, first);
      expect(second.hashCode, first.hashCode);
      expect(second.select(grid, 5, looping: true), isNot(first));
    });
  });

  group('SceneTrack / ScenePlane — NativeSceneInput.cpp:116-134', () {
    test('the untouched wall sits at lane 2, row 12', () {
      expect(SceneTrack.origin.lane, 0);
      expect(SceneTrack.origin.row, 0);
      final ScenePlane plane = sceneTrackPlane(SceneTrack.origin);
      expect(plane.lane, closeTo(2.0, 1e-12));
      expect(plane.row, closeTo(12.0, 1e-9));
    });

    test('one lane pitch and one rail pitch move exactly one lane and one row', () {
      final ScenePlane plane =
          sceneTrackPlane(const SceneTrack(lane: kLanePitch, row: -kRowPitch));
      expect(plane.lane, closeTo(3.0, 1e-12));
      expect(plane.row, closeTo(13.0, 1e-9));
    });

    test('the rail grows against the row axis', () {
      expect(sceneTrackPlane(const SceneTrack(lane: 0, row: -kRowPitch)).row, closeTo(13.0, 1e-9));
      expect(sceneTrackPlane(const SceneTrack(lane: 0, row: kRowPitch)).row, closeTo(11.0, 1e-9));
      expect(sceneTrackPlane(const SceneTrack(lane: 0, row: -kRowPitch)).lane, closeTo(2.0, 1e-12));
    });

    test('a drag adds lanes and subtracts rows from the start track', () {
      const SceneTrack start = SceneTrack(lane: 2.0, row: -1.0);
      final SceneTrack track = sceneArchiveTrack(start: start, dragLane: 2.0, dragRow: 3.0);
      expect(track.lane, closeTo(2.0 + 2.0 * kLanePitch, 1e-9));
      expect(track.row, closeTo(-1.0 - 3.0 * kRowPitch, 1e-9));
    });

    test('origin plus a one-lane drag targets the next lane at the same row', () {
      final List<SceneCell> path = sceneDragPath(
        start: SceneTrack.origin,
        dragLane: 1,
        dragRow: 0,
        from: const SceneCell(2, 12),
      );
      expectPath(path, <List<int>>[<int>[3, 12]]);
      expect(path, hasLength(1));
    });

    test('origin plus a one-row drag targets the next row', () {
      final List<SceneCell> path = sceneDragPath(
        start: SceneTrack.origin,
        dragLane: 0,
        dragRow: 1,
        from: const SceneCell(2, 12),
      );
      expectPath(path, <List<int>>[<int>[2, 13]]);
    });

    test('a two-lane drag leaves a two-cell path', () {
      final List<SceneCell> path = sceneDragPath(
        start: SceneTrack.origin,
        dragLane: 2,
        dragRow: 0,
        from: const SceneCell(2, 12),
      );
      expectPath(path, <List<int>>[<int>[3, 12], <int>[4, 12]]);
    });

    test('a negative drag walks back one lane', () {
      final List<SceneCell> path = sceneDragPath(
        start: SceneTrack.origin,
        dragLane: -1,
        dragRow: 0,
        from: const SceneCell(2, 12),
      );
      expectPath(path, <List<int>>[<int>[1, 12]]);
    });
  });

  group('scenePlaneTarget / scenePlanePath — NativeSceneInput.cpp:99-114', () {
    test('rounds half up on both axes', () {
      expectCell(scenePlaneTarget(const ScenePlane(lane: 2.4, row: 12.6)), 2, 13);
      expectCell(scenePlaneTarget(const ScenePlane(lane: 2.5, row: 12.5)), 3, 13);
      expectCell(scenePlaneTarget(const ScenePlane(lane: -2.5, row: -0.5)), -2, 0);
      expectCell(scenePlaneTarget(const ScenePlane(lane: 2.0, row: 12.0)), 2, 12);
    });

    test('a goal equal to the occupied cell walks nowhere', () {
      expect(
        scenePlanePath(from: const SceneCell(2, 12), target: const ScenePlane(lane: 2.0, row: 12.0)),
        isEmpty,
      );
      expect(
        scenePlanePath(from: const SceneCell(2, 12), target: const ScenePlane(lane: 2.4, row: 12.4)),
        isEmpty,
      );
    });

    test('a vertical drag walks one cell per row', () {
      final List<SceneCell> path = scenePlanePath(
        from: const SceneCell(2, 12),
        target: const ScenePlane(lane: 2.0, row: 18.0),
      );
      expectPath(path, <List<int>>[
        <int>[2, 13],
        <int>[2, 14],
        <int>[2, 15],
        <int>[2, 16],
        <int>[2, 17],
        <int>[2, 18],
      ]);
    });

    test('a diagonal drag interpolates both axes', () {
      final List<SceneCell> path = scenePlanePath(
        from: const SceneCell(2, 12),
        target: const ScenePlane(lane: 5.0, row: 13.0),
      );
      expectPath(path, <List<int>>[
        <int>[3, 12],
        <int>[4, 13],
        <int>[5, 13],
      ]);
    });

    test('a long walk is capped at 64 cells and ends on the goal cell', () {
      final List<SceneCell> path = scenePlanePath(
        from: const SceneCell(2, 12),
        target: const ScenePlane(lane: 2.0, row: 112.0),
      );
      expect(path, hasLength(64));
      expectCell(path.first, 2, 14);
      expectCell(path.last, 2, 112);
      for (int index = 1; index < path.length; ++index) {
        expect(path[index].row, greaterThan(path[index - 1].row));
        expect(path[index].lane, 2);
      }
    });

    test('the cap also applies across lanes', () {
      final List<SceneCell> path = scenePlanePath(
        from: const SceneCell(2, 12),
        target: const ScenePlane(lane: 200.0, row: 12.0),
      );
      expect(path, hasLength(64));
      expectCell(path.last, 200, 12);
    });

    test('the path is unmodifiable', () {
      final List<SceneCell> path = scenePlanePath(
        from: const SceneCell(2, 12),
        target: const ScenePlane(lane: 2.0, row: 13.0),
      );
      expect(() => path.add(const SceneCell(0, 0)), throwsUnsupportedError);
    });
  });

  group('sceneDragProjection — NativeSceneInput.cpp:24-33', () {
    test('an identity view turns one lane step into half the surface width', () {
      final SceneDragProjection projection = sceneDragProjection(
        matrix: Mat4(),
        actorPosition: Vec3.zero,
        actorRotation: Vec3.zero,
        width: 1920,
        height: 1080,
      );
      // -5.2 * 1920 / 2 == -4992, and the lane probe has no y or z component.
      expect(projection.lane.dx, closeTo(-4992.0, 1e-9));
      expect(projection.lane.dy, 0.0);
      // The row probe runs along -z only, which the identity view does not move on screen.
      expect(projection.row.dx, 0.0);
      expect(projection.row.dy, 0.0);
    });

    test('the pixel step scales with the surface size', () {
      final SceneDragProjection small = sceneDragProjection(
        matrix: Mat4(),
        actorPosition: Vec3.zero,
        actorRotation: Vec3.zero,
        width: 960,
        height: 540,
      );
      final SceneDragProjection large = sceneDragProjection(
        matrix: Mat4(),
        actorPosition: Vec3.zero,
        actorRotation: Vec3.zero,
        width: 1920,
        height: 1080,
      );
      expect(small.lane.dx, closeTo(-2496.0, 1e-9));
      expect(large.lane.dx, closeTo(small.lane.dx * 2, 1e-9));
    });

    test('the probe height does not shift a translation-only view', () {
      final SceneDragProjection a = sceneDragProjection(
        matrix: Mat4(),
        actorPosition: Vec3.zero,
        actorRotation: Vec3.zero,
        width: 1920,
        height: 1080,
      );
      final SceneDragProjection b = sceneDragProjection(
        matrix: Mat4(),
        actorPosition: const Vec3(3.0, -4.6, 7.0),
        actorRotation: Vec3.zero,
        width: 1920,
        height: 1080,
      );
      expect(b.lane.dx, closeTo(a.lane.dx, 1e-9));
      expect(b.lane.dy, 0.0);
      expect(b.row.dx, 0.0);
      expect(b.row.dy, 0.0);
    });
  });

  group('scenePointerMoved / sceneTapSelects — NativeSceneInput.cpp:172,183-196', () {
    test('seven logical pixels is still a tap, anything past it is a drag', () {
      expect(scenePointerMoved(downX: 0, downY: 0, x: 7, y: 0), isFalse);
      expect(scenePointerMoved(downX: 0, downY: 0, x: 0, y: 7), isFalse);
      expect(scenePointerMoved(downX: 0, downY: 0, x: 7.01, y: 0), isTrue);
      expect(scenePointerMoved(downX: 0, downY: 0, x: 3, y: 4), isFalse); // hypot 5
      expect(scenePointerMoved(downX: 0, downY: 0, x: 5, y: 5), isTrue); // hypot ~7.07
      expect(scenePointerMoved(downX: 100, downY: -50, x: 100, y: -50), isFalse);
      expect(scenePointerMoved(downX: 100, downY: -50, x: 107.5, y: -50), isTrue);
    });

    test('a captured tap selects only when browsing, allowed, not dragging and not moved', () {
      expect(
        sceneTapSelects(
          captured: true,
          browsing: true,
          canBrowse: true,
          dragActive: false,
          moved: false,
        ),
        isTrue,
      );
      expect(
        sceneTapSelects(
          captured: true,
          browsing: true,
          canBrowse: true,
          dragActive: true,
          moved: false,
        ),
        isFalse,
      );
      expect(
        sceneTapSelects(
          captured: true,
          browsing: true,
          canBrowse: true,
          dragActive: false,
          moved: true,
        ),
        isFalse,
      );
      expect(
        sceneTapSelects(
          captured: true,
          browsing: true,
          canBrowse: false,
          dragActive: false,
          moved: false,
        ),
        isFalse,
      );
      expect(
        sceneTapSelects(
          captured: true,
          browsing: false,
          canBrowse: true,
          dragActive: false,
          moved: false,
        ),
        isFalse,
      );
      // NativeSceneInput.cpp:183 — an uncaptured pointerup never reaches the
      // select branch, so every other flag being true still must not select.
      expect(
        sceneTapSelects(
          captured: false,
          browsing: true,
          canBrowse: true,
          dragActive: false,
          moved: false,
        ),
        isFalse,
      );
    });
  });

  group('sceneRebaseShift — NativeSceneInput.cpp:201-210', () {
    test('does nothing inside the 2048-cell window', () {
      expect(sceneRebaseShift(const SceneCell(2048, 12)), isNull);
      expect(sceneRebaseShift(const SceneCell(12, 2044)), isNull);
      expect(sceneRebaseShift(const SceneCell(-2048, -2048)), isNull);
      expect(sceneRebaseShift(const SceneCell(2, 12)), isNull);
    });

    test('folds lanes by five around lane 2', () {
      expectCell(sceneRebaseShift(const SceneCell(2050, 12))!, 2050, 0);
      expectCell(sceneRebaseShift(const SceneCell(-2050, 12))!, -2050, 0);
      // 2049 folds to 2045, leaving lane 4: the residue of 2049 modulo 5.
      expectCell(sceneRebaseShift(const SceneCell(2049, 12))!, 2045, 0);
      expectCell(sceneRebaseShift(const SceneCell(-2049, 12))!, -2050, 0);
    });

    test('folds rows by eight from row 12 with a plain floor', () {
      expectCell(sceneRebaseShift(const SceneCell(12, 2050))!, 0, 2032);
      expectCell(sceneRebaseShift(const SceneCell(12, 2049))!, 0, 2032);
      expectCell(sceneRebaseShift(const SceneCell(12, -2049))!, 0, -2064);
    });

    test('a shift only appears on the axis that overflowed', () {
      expectCell(sceneRebaseShift(const SceneCell(2051, 12))!, 2050, 0);
      expectCell(sceneRebaseShift(const SceneCell(12, 2051))!, 0, 2032);
    });

    test('both axes can shift at once, and the shift is what rebase subtracts', () {
      final SceneCell? shift = sceneRebaseShift(const SceneCell(2051, 2051));
      expect(shift, isNotNull);
      expectCell(shift!, 2050, 2032);
      final SceneCell folded = SceneCell(2051 - shift.lane, 2051 - shift.row);
      expectCell(folded, 1, 19);
    });
  });
}
