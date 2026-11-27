// Qt -> Flutter 迁移 · SHARED-S4 测试规格：媒体状态共同值对象（MediaSnapshot）。
//
// 覆盖本原子的全部可写域行为（每条断言上方注释给出 Qt 依据行号）：
//   Qt/src/AndroidMediaSession.h:19-22  update(playing, positionMs, durationMs, title, artist, album,
//                                       coverPath = {})：七个字段的来源与顺序，coverPath 默认空值
//   Qt/src/AndroidMediaSession.h:19-20  title 为空或 duration <= 0 表示转入待机；coverPath 空 = 无封面
//   Qt/src/AndroidMediaSession.h:24-25  stop()：待机动作（本类型只提供只读判据 isStandby）
//   Qt/src/PlatformAndroid.cpp:62-71    platformMediaInfo()：:64 待机判据，:69-71 ensureStarted + update
//   Qt/src/Platform.mm:170-181          iOS 侧同一共同元组，:177 待机判据逐字一致
//
// 【本测试未执行】受任务禁令约束：禁止 flutter test / dart test / dart analyze / 构建 / 代码生成
// 以及任何形式的测试执行。RED/GREEN 结论留待集成侧记录（候选命令：
// flutter test test/domain/media_snapshot_test.dart）。
// 依赖说明：按项目既有约定 import package:flutter_test/flutter_test.dart
// （pubspec.yaml dev_dependencies 已含 flutter_test）；不新增依赖、不改 pubspec。
//
// 断言边界说明（本类型不做数值解析，只承载已解析值）：
// QVariant::toLongLong() 的退化语义（缺失 / 空串 / 非数值 → 0）属于调用方边界
// （PlatformAndroid.cpp:70-71），因此 durationMs == 0 与 durationMs < 0 都必须判定为待机。
import 'package:flutter_test/flutter_test.dart';

import 'package:rhine_music_database/domain/models/media_snapshot.dart';

void main() {
  group('R1 待机判据 isStandby（PlatformAndroid.cpp:64 与 AndroidMediaSession.h:19-20）', () {
    test('R1 title 为空 → true（durationMs 为正也一样）', () {
      // PlatformAndroid.cpp:64 `title.isEmpty() || ...` 的左支短路。
      const s = MediaSnapshot(
        playing: true,
        positionMs: 1000,
        durationMs: 180000,
        title: '',
        artist: 'a',
        album: 'b',
      );
      expect(s.isStandby, isTrue);
    });

    test('R1 durationMs 为 0 → true（title 非空）', () {
      // PlatformAndroid.cpp:64 右支 `... duration.toLongLong() <= 0`；Qt 的 <= 含等号。
      const s = MediaSnapshot(
        playing: false,
        positionMs: 0,
        durationMs: 0,
        title: '歌名',
        artist: 'a',
        album: 'b',
      );
      expect(s.isStandby, isTrue);
    });

    test('R1 durationMs 为负且 title 非空 → true', () {
      // PlatformAndroid.cpp:64：负数同样满足 <= 0，Qt 不做非负钳制。
      const s = MediaSnapshot(
        playing: false,
        positionMs: -1,
        durationMs: -1,
        title: '歌名',
        artist: 'a',
        album: 'b',
      );
      expect(s.isStandby, isTrue);
    });

    test('R1 title 非空且 durationMs 大于 0 → false', () {
      // PlatformAndroid.cpp:64 两个条件都不成立，走 :69-71 的 ensureStarted + update 分支。
      const s = MediaSnapshot(
        playing: true,
        positionMs: 1,
        durationMs: 1,
        title: '歌名',
        artist: 'a',
        album: 'b',
      );
      expect(s.isStandby, isFalse);
    });

    test('R1 title 与 durationMs 同时退化 → true（并集，无额外条件）', () {
      // PlatformAndroid.cpp:64 是 `||`，不是 `&&`：任一成立即待机。
      const s = MediaSnapshot(
        playing: true,
        positionMs: 0,
        durationMs: 0,
        title: '',
        artist: '',
        album: '',
      );
      expect(s.isStandby, isTrue);
    });
  });

  group('R2 七个字段存取（AndroidMediaSession.h:21-22 形参顺序）', () {
    test('R2 七个字段原样保存且类型为 bool/int/int/String/String/String/String', () {
      const s = MediaSnapshot(
        playing: true,
        positionMs: 12345,
        durationMs: 234567,
        title: '标题',
        artist: '艺术家',
        album: '专辑',
        coverPath: '/data/user/0/x/cache/media-cover.png',
      );
      expect(s.playing, isTrue);
      expect(s.positionMs, 12345);
      expect(s.durationMs, 234567);
      expect(s.title, '标题');
      expect(s.artist, '艺术家');
      expect(s.album, '专辑');
      expect(s.coverPath, '/data/user/0/x/cache/media-cover.png');
    });

    test('R2 字段顺序与 Qt 一致：playing/positionMs/durationMs 在前，四个字符串在后', () {
      // 名字型构造的参数书写顺序不改变语义，此处只锁类型与互不串位。
      const s = MediaSnapshot(
        playing: false,
        positionMs: 7,
        durationMs: 9,
        title: '7',
        artist: '9',
        album: '7',
        coverPath: '9',
      );
      expect(s.positionMs, 7);
      expect(s.durationMs, 9);
      expect(s.title, '7');
      expect(s.artist, '9');
      expect(s.album, '7');
      expect(s.coverPath, '9');
    });
  });

  group('R3 coverPath 默认值（AndroidMediaSession.h:20,22）', () {
    test('R3 省略 coverPath 时为空串（对齐 Qt 的默认实参，见 AndroidMediaSession.h:22）', () {
      const s = MediaSnapshot(
        playing: false,
        positionMs: 0,
        durationMs: 60000,
        title: 't',
        artist: 'a',
        album: 'b',
      );
      expect(s.coverPath, '');
      expect(s.coverPath.isEmpty, isTrue);
    });

    test('R3 显式传空串与省略等价（空串 = 无封面，不是 null）', () {
      const omitted = MediaSnapshot(
        playing: false,
        positionMs: 0,
        durationMs: 60000,
        title: 't',
        artist: 'a',
        album: 'b',
      );
      const explicit = MediaSnapshot(
        playing: false,
        positionMs: 0,
        durationMs: 60000,
        title: 't',
        artist: 'a',
        album: 'b',
        coverPath: '',
      );
      expect(explicit, omitted);
    });
  });

  group('R4 值相等语义（纯数据值对象）', () {
    test('R4 七字段全等 → == 且 hashCode 相等', () {
      const a = MediaSnapshot(
        playing: true,
        positionMs: 1,
        durationMs: 2,
        title: 't',
        artist: 'a',
        album: 'b',
        coverPath: 'c',
      );
      const b = MediaSnapshot(
        playing: true,
        positionMs: 1,
        durationMs: 2,
        title: 't',
        artist: 'a',
        album: 'b',
        coverPath: 'c',
      );
      expect(a == b, isTrue);
      expect(a.hashCode, b.hashCode);
      expect({a, b}.length, 1);
    });

    test('R4 任一字段不同 → 不相等（逐字段检查七个位置）', () {
      const base = MediaSnapshot(
        playing: true,
        positionMs: 1,
        durationMs: 2,
        title: 't',
        artist: 'a',
        album: 'b',
        coverPath: 'c',
      );
      const variants = <MediaSnapshot>[
        MediaSnapshot(
          playing: false,
          positionMs: 1,
          durationMs: 2,
          title: 't',
          artist: 'a',
          album: 'b',
          coverPath: 'c',
        ),
        MediaSnapshot(
          playing: true,
          positionMs: 9,
          durationMs: 2,
          title: 't',
          artist: 'a',
          album: 'b',
          coverPath: 'c',
        ),
        MediaSnapshot(
          playing: true,
          positionMs: 1,
          durationMs: 9,
          title: 't',
          artist: 'a',
          album: 'b',
          coverPath: 'c',
        ),
        MediaSnapshot(
          playing: true,
          positionMs: 1,
          durationMs: 2,
          title: 'T',
          artist: 'a',
          album: 'b',
          coverPath: 'c',
        ),
        MediaSnapshot(
          playing: true,
          positionMs: 1,
          durationMs: 2,
          title: 't',
          artist: 'A',
          album: 'b',
          coverPath: 'c',
        ),
        MediaSnapshot(
          playing: true,
          positionMs: 1,
          durationMs: 2,
          title: 't',
          artist: 'a',
          album: 'B',
          coverPath: 'c',
        ),
        MediaSnapshot(
          playing: true,
          positionMs: 1,
          durationMs: 2,
          title: 't',
          artist: 'a',
          album: 'b',
          coverPath: 'C',
        ),
      ];
      for (final v in variants) {
        expect(v == base, isFalse);
      }
    });

    test('R4 == 对不同类型对象返回 false（不抛异常）', () {
      const s = MediaSnapshot(
        playing: false,
        positionMs: 0,
        durationMs: 0,
        title: '',
        artist: '',
        album: '',
      );
      // ignore: unrelated_type_equality_checks
      expect(s == Object(), isFalse);
    });

    test('R4 const 构造：同字面量实例 identical（const 规范化）', () {
      const a = MediaSnapshot(
        playing: true,
        positionMs: 1,
        durationMs: 2,
        title: 't',
        artist: 'a',
        album: 'b',
      );
      const b = MediaSnapshot(
        playing: true,
        positionMs: 1,
        durationMs: 2,
        title: 't',
        artist: 'a',
        album: 'b',
      );
      expect(identical(a, b), isTrue);
    });
  });

  group('R5 copyWith（纯值语义的部分更新）', () {
    test('R5 无参 copyWith 得到相等实例', () {
      const s = MediaSnapshot(
        playing: true,
        positionMs: 3,
        durationMs: 4,
        title: 't',
        artist: 'a',
        album: 'b',
        coverPath: 'c',
      );
      expect(s.copyWith(), s);
    });

    test('R5 只改 durationMs：其余字段保留，isStandby 随之翻转', () {
      const active = MediaSnapshot(
        playing: true,
        positionMs: 3,
        durationMs: 4,
        title: 't',
        artist: 'a',
        album: 'b',
        coverPath: 'c',
      );
      final standby = active.copyWith(durationMs: 0);
      expect(standby.isStandby, isTrue);
      expect(standby.title, 't');
      expect(standby.playing, isTrue);
      expect(standby.positionMs, 3);
      expect(standby.coverPath, 'c');
      expect(identical(standby, active), isFalse);
    });

    test('R5 只改 title 为空串 → 待机', () {
      const active = MediaSnapshot(
        playing: true,
        positionMs: 3,
        durationMs: 4,
        title: 't',
        artist: 'a',
        album: 'b',
      );
      expect(active.copyWith(title: '').isStandby, isTrue);
    });
  });

  group('R6 toString（仅诊断用，不参与相等）', () {
    test('R6 含全部七个字段值', () {
      const s = MediaSnapshot(
        playing: true,
        positionMs: 1,
        durationMs: 2,
        title: 'T',
        artist: 'A',
        album: 'B',
        coverPath: 'C',
      );
      final text = s.toString();
      expect(text.contains('MediaSnapshot'), isTrue);
      for (final needle in <String>['true', '1', '2', 'T', 'A', 'B', 'C']) {
        expect(text.contains(needle), isTrue);
      }
    });
  });
}
