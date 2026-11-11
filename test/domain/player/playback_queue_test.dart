/// 播放传输依赖的队列契约测试（未执行：本任务禁止 flutter test / dart test）。
///
/// 证据源：Qt/src/PlaybackQueue.cpp（各用例注释给出 Qt 行号）、
/// lib/domain/player/playback_queue.dart。
library;

import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:rhine_music_database/domain/player/playback_queue.dart';

Map<String, Object?> song(String id, {String provider = 'netease'}) {
  return <String, Object?>{
    'kind': 'song',
    'id': id,
    'provider': provider,
    'title': 'T' + id,
  };
}

List<Object?> ids(PlaybackQueue queue) => <Object?>[for (final track in queue.items) track['id']];

class FakePort implements QueueMetadataPort {
  FakePort(this.provider);

  @override
  final String provider;

  @override
  Future<List<Map<String, Object?>>> songs(List<String> ids) async =>
      <Map<String, Object?>>[for (final id in ids) song(id, provider: provider)];
}

void main() {
  group('replace / enqueue（PlaybackQueue.cpp:113-171）', () {
    test('replace 按身份选中并剔除无效项（:113-117）', () {
      final queue = PlaybackQueue(null);
      queue.replace(<Map<String, Object?>>[song('a'), <String, Object?>{'kind': 'video', 'id': 'v'}, song('a'), song('b')], song('b'));
      expect(ids(queue), <Object?>['a', 'b']);
      expect(queue.index, 1);
    });

    test('next 插到当前项之后（:167-168）', () {
      final queue = PlaybackQueue(null);
      queue.replace(<Map<String, Object?>>[song('a'), song('b'), song('c')]);
      queue.select(1);
      expect(queue.enqueue(song('d'), next: true), isTrue);
      expect(ids(queue), <Object?>['a', 'b', 'd', 'c']);
      expect(queue.index, 1);
    });

    test('默认追加到队尾（:167）', () {
      final queue = PlaybackQueue(null);
      queue.replace(<Map<String, Object?>>[song('a'), song('b')]);
      queue.select(0);
      expect(queue.enqueue(song('c')), isTrue);
      expect(ids(queue), <Object?>['a', 'b', 'c']);
      expect(queue.index, 0);
    });

    test('非歌曲与跨来源被拒绝（:150-156）', () {
      final local = PlaybackQueue(FakePort('local'));
      expect(local.enqueue(song('a')), isFalse);
      expect(local.enqueue(<String, Object?>{'kind': 'video', 'id': 'v'}), isFalse);
      expect(local.isEmpty, isTrue);
    });

    test('同曲去重且索引随删除前移（:157-166）', () {
      final queue = PlaybackQueue(null);
      queue.replace(<Map<String, Object?>>[song('a'), song('b'), song('c')]);
      queue.select(1);
      expect(queue.enqueue(song('a'), next: true), isTrue);
      expect(ids(queue), <Object?>['b', 'a', 'c']);
      expect(queue.index, 0);
    });
  });

  group('remove / clearUpcoming（PlaybackQueue.cpp:173-204）', () {
    test('remove 拒绝越界与当前项（:173-183）', () {
      final queue = PlaybackQueue(null);
      queue.replace(<Map<String, Object?>>[song('a'), song('b'), song('c')]);
      queue.select(1);
      expect(queue.remove(-1), isFalse);
      expect(queue.remove(3), isFalse);
      expect(queue.remove(1), isFalse);
      expect(queue.remove(2), isTrue);
      expect(ids(queue), <Object?>['a', 'b']);
      expect(queue.index, 1);
    });

    test('clearUpcoming 只保留当前项（:193-204）', () {
      final queue = PlaybackQueue(null);
      queue.replace(<Map<String, Object?>>[song('a'), song('b'), song('c')]);
      queue.select(1);
      queue.clearUpcoming(queue.current());
      expect(ids(queue), <Object?>['b']);
      expect(queue.index, 0);
    });

    test('clearUpcoming 无当前项时清空（:196-198）', () {
      final queue = PlaybackQueue(null);
      queue.replace(<Map<String, Object?>>[song('a')]);
      queue.clearUpcoming(<String, Object?>{});
      expect(queue.isEmpty, isTrue);
      expect(queue.index, -1);
    });
  });

  group('navigate（PlaybackQueue.cpp:256-283）', () {
    test('off 到末尾返回 -1 且不改索引（:277-279）', () {
      final queue = PlaybackQueue(null);
      queue.replace(<Map<String, Object?>>[song('a'), song('b')]);
      queue.select(1);
      expect(queue.navigate(1, 'off'), -1);
      expect(queue.index, 1);
    });

    test('one 返回当前索引（:261-262）', () {
      final queue = PlaybackQueue(null);
      queue.replace(<Map<String, Object?>>[song('a'), song('b'), song('c')]);
      queue.select(1);
      expect(queue.navigate(-1, 'one'), 1);
      expect(queue.navigate(1, 'one'), 1);
      expect(queue.index, 1);
    });

    test('顺序推进环绕到队首（:280-282）', () {
      final queue = PlaybackQueue(null);
      queue.replace(<Map<String, Object?>>[song('a'), song('b')]);
      queue.select(1);
      expect(queue.navigate(1, 'all'), 0);
      expect(queue.index, 0);
    });

    test('shuffle 后退沿实际播放历史（:264-271）', () {
      final queue = PlaybackQueue(null, random: math.Random(1));
      queue.replace(<Map<String, Object?>>[song('a'), song('b'), song('c')]);
      queue.select(0);
      queue.select(1);
      expect(queue.navigate(-1, 'shuffle'), 0);
      expect(queue.index, 0);
    });
  });

  group('restore / toJson（PlaybackQueue.cpp:398-420）', () {
    test('restore 只接受完整曲目，deferred 留给补全（:398-419）', () {
      final queue = PlaybackQueue(null);
      queue.restore(<Map<String, Object?>>[
        song('a'),
        <String, Object?>{'kind': 'song', 'id': 'd', 'deferred': true},
        <String, Object?>{'kind': 'video', 'id': 'v'},
      ], 0, true);
      expect(ids(queue), <Object?>['a']);
      expect(queue.index, 0);
      expect(queue.isLoading, isFalse);
    });

    test('toJson 返回完整条目（:420）', () {
      final queue = PlaybackQueue(null);
      queue.replace(<Map<String, Object?>>[song('a'), song('b')]);
      expect(queue.toJson(), queue.items);
      expect(PlaybackQueue.identity(queue.toJson().first), 'netease:a');
    });
  });
}
