/// 队列不变量测试（未执行：本任务禁止 flutter test / dart test）。
/// 证据源：Qt/src/PlaybackQueue.h、Qt/src/PlaybackQueue.cpp
/// 第二轮（T23-C18）：按 T23-C14-queue-review 修复 M1/M2 错误期望（断言与 Qt 及产品实现都矛盾），
/// 并补齐 M3-M8 六条计划点名但原先零覆盖的不变量；M6 用例经独立复核指出不具判别力后，
/// 改为「被删历史项与 fallback 行不重合」的构造（正确实现 2/2/'c'，单弹 mutation 0/0/'a'）。
/// 产品代码 lib/domain/player/playback_queue.dart 未改动。
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:rhine_music_database/domain/player/playback_queue.dart';

Map<String, Object?> song(String id, {String provider = 'netease', Object? extra}) => {
      'kind': 'song',
      'id': id,
      'provider': provider,
      'title': 'T$id',
      if (extra is Map) ...extra.cast<String, Object?>(),
    };

class FakePort implements QueueMetadataPort {
  FakePort(this.provider, {this.handler});

  @override
  final String provider;

  Future<List<Map<String, Object?>>> Function(List<String> ids)? handler;
  final List<List<String>> calls = <List<String>>[];

  @override
  Future<List<Map<String, Object?>>> songs(List<String> ids) async {
    calls.add(List<String>.of(ids));
    final h = handler;
    if (h != null) {
      return h(ids);
    }
    return [for (final id in ids) song(id, provider: provider)];
  }
}

List<Object?> ids(PlaybackQueue q) => [for (final t in q.items) t['id']];

void main() {
  group('identity', () {
    test('provider 缺省 netease，显式空串保留为空', () {
      expect(PlaybackQueue.identity(<String, Object?>{'id': 'a'}), 'netease:a');
      expect(PlaybackQueue.identity(<String, Object?>{'id': 'a', 'provider': 'qq'}), 'qq:a');
      expect(PlaybackQueue.identity(<String, Object?>{'id': 'a', 'provider': ''}), ':a');
      expect(PlaybackQueue.identity(<String, Object?>{'kind': 'song'}), 'netease:');
    });
  });

  group('replace / sanitize', () {
    test('剔除非歌曲与空 ID，按身份去重，selected 决定索引', () {
      final q = PlaybackQueue(FakePort('netease'));
      q.replace(<Map<String, Object?>>[
        song('a'),
        song('b'),
        song('b', extra: {'title': 'dup'}),
        <String, Object?>{'kind': 'album', 'id': 'x'},
        song(''),
      ], song('b'));
      expect(ids(q), <Object?>['a', 'b']);
      expect(q.index, 1);
      expect(q.current()['id'], 'b');
      expect(q.size, 2);
      expect(q.isEmpty, isFalse);
    });

    test('selected 不在队列内则索引为 -1', () {
      final q = PlaybackQueue(FakePort('netease'));
      q.replace(<Map<String, Object?>>[song('a')], song('zzz'));
      expect(q.index, -1);
      expect(q.current(), isEmpty);
    });

    test('replace 清空随机历史', () {
      final q = PlaybackQueue(FakePort('netease'), random: math.Random(1));
      // replace 未传 selected 时索引为 -1，此时 select 不会记历史（rememberCurrent 直接返回），
      // 所以必须先给出 selected 才能造出真实播放历史。
      q.replace(<Map<String, Object?>>[song('a'), song('b'), song('c')], song('a'));
      q.select(1);
      q.select(2);
      // 此刻历史 = [a, b]（Qt PlaybackQueue.cpp:214-226 rememberCurrent）。
      q.replace(<Map<String, Object?>>[song('a'), song('b'), song('c')], song('a'));
      // 历史已清空 → shuffle 后退走 fallback：(0-1) 欧几里得模回绕到队尾 2。
      // 若 replace 未清历史，_takeShuffledPrevious 会弹出 b 回到第 1 行。
      expect(q.navigate(-1, 'shuffle'), 2);
      expect(q.index, 2);
      expect(q.current()['id'], 'c');
    });
  });

  group('syncSnapshot', () {
    test('设置条目与索引且不通知（调用方负责绘制）', () {
      final q = PlaybackQueue(FakePort('netease'));
      var notified = 0;
      q.addListener(() => notified++);
      q.syncSnapshot(<Map<String, Object?>>[song('a'), song('b')], 1);
      expect(ids(q), <Object?>['a', 'b']);
      expect(q.index, 1);
      expect(notified, 0);
      q.syncSnapshot(<Map<String, Object?>>[song('a')], 9);
      expect(q.index, -1);
      expect(notified, 0);
    });
  });

  group('select / selectTrack', () {
    test('select 越界或同索引不动', () {
      final q = PlaybackQueue(FakePort('netease'));
      q.replace(<Map<String, Object?>>[song('a'), song('b')]);
      q.select(0);
      var notified = 0;
      q.addListener(() => notified++);
      q.select(0);
      q.select(5);
      q.select(-1);
      expect(q.index, 0);
      expect(notified, 0);
    });

    test('selectTrack 命中当前不重复通知，命中他项移动，未命中追加并记住上一首', () {
      final q = PlaybackQueue(FakePort('netease'));
      q.replace(<Map<String, Object?>>[song('a'), song('b')], song('a'));
      var notified = 0;
      q.addListener(() => notified++);
      q.selectTrack(song('a'));
      expect(notified, 0);
      q.selectTrack(song('b'));
      expect(q.index, 1);
      expect(notified, 1);
      q.selectTrack(song('c'));
      expect(ids(q), <Object?>['a', 'b', 'c']);
      expect(q.index, 2);
      // c 之前记住的是 b，随机后退应回到 b。
      expect(q.navigate(-1, 'shuffle'), 1);
    });

    test('selectTrack 拒绝非法条目', () {
      final q = PlaybackQueue(FakePort('netease'));
      // 必须传 selected：replace 省略 selected 时索引为 -1（该语义由上一个用例覆盖），
      // 否则本用例断言的是「非法 selectTrack 未把 -1 改回 0」而非拒绝逻辑。
      q.replace(<Map<String, Object?>>[song('a')], song('a'));
      q.selectTrack(<String, Object?>{'kind': 'album', 'id': 'x'});
      q.selectTrack(song(''));
      expect(q.size, 1);
      expect(q.index, 0);
      expect(q.current()['id'], 'a');
    });
  });

  group('enqueue', () {
    test('非当前重复项被移除并重新插入，索引随之下调', () {
      final q = PlaybackQueue(FakePort('netease'));
      q.replace(<Map<String, Object?>>[song('a'), song('b'), song('c')], song('c'));
      expect(q.index, 2);
      expect(q.enqueue(song('a')), isTrue);
      expect(ids(q), <Object?>['b', 'c', 'a']);
      expect(q.index, 1);
    });

    test('next 插到当前项之后，否则追加', () {
      final q = PlaybackQueue(FakePort('netease'));
      q.replace(<Map<String, Object?>>[song('a'), song('b')], song('a'));
      q.enqueue(song('x'), next: true);
      expect(ids(q), <Object?>['a', 'x', 'b']);
      q.enqueue(song('y'));
      expect(ids(q), <Object?>['a', 'x', 'b', 'y']);
    });

    test('索引为 -1 时 next 插到队首', () {
      final q = PlaybackQueue(FakePort('netease'));
      q.replace(<Map<String, Object?>>[song('a')]);
      q.enqueue(song('x'), next: true);
      expect(ids(q), <Object?>['x', 'a']);
    });

    test('本地与非本地来源互不混入', () {
      final local = PlaybackQueue(FakePort('local'));
      local.replace(<Map<String, Object?>>[song('a', provider: 'local')]);
      expect(local.enqueue(song('b')), isFalse);
      expect(local.enqueue(song('b', provider: 'local')), isTrue);

      final remote = PlaybackQueue(FakePort('netease'));
      remote.replace(<Map<String, Object?>>[song('a')]);
      expect(remote.enqueue(song('b', provider: 'local')), isFalse);
      expect(remote.enqueue(song('b')), isTrue);
    });

    test('拒绝非法条目', () {
      final q = PlaybackQueue(FakePort('netease'));
      expect(q.enqueue(<String, Object?>{'kind': 'album', 'id': 'x'}), isFalse);
      expect(q.enqueue(song('')), isFalse);
      expect(q.isEmpty, isTrue);
    });

    test('当前项允许重复入队（去重循环跳过当前行）', () {
      final q = PlaybackQueue(FakePort('netease'));
      q.replace(<Map<String, Object?>>[song('a'), song('b')], song('a'));
      // Qt PlaybackQueue.cpp:158-166（enqueue 全函数 149-171）的去重循环显式跳 row == m_index，当前曲可以再入队。
      expect(q.enqueue(song('a')), isTrue);
      expect(ids(q), <Object?>['a', 'b', 'a']);
      expect(q.index, 0);
      // next 时先摘掉「非当前」的重复项，再插到当前项之后：position = max(0, 0+1) = 1。
      expect(q.enqueue(song('a'), next: true), isTrue);
      expect(ids(q), <Object?>['a', 'a', 'b']);
      expect(q.index, 0);
    });
  });

  group('remove / updateCurrent', () {
    test('remove 拒绝当前项与越界，删除前项下调索引', () {
      final q = PlaybackQueue(FakePort('netease'));
      q.replace(<Map<String, Object?>>[song('a'), song('b'), song('c')], song('c'));
      expect(q.remove(2), isFalse);
      expect(q.remove(7), isFalse);
      expect(q.remove(0), isTrue);
      expect(ids(q), <Object?>['b', 'c']);
      expect(q.index, 1);
      expect(q.remove(0), isTrue);
      expect(q.index, 0);
      expect(q.current()['id'], 'c');
    });

    test('updateCurrent 身份不一致忽略，一致则替换当前项', () {
      final q = PlaybackQueue(FakePort('netease'));
      q.replace(<Map<String, Object?>>[song('a'), song('b')], song('a'));
      q.updateCurrent(song('b'));
      expect(q.current()['id'], 'a');
      q.updateCurrent(song('a', extra: {'cover': 'u'}));
      expect(q.current()['cover'], 'u');
    });
  });

  group('clearUpcoming / clear', () {
    test('有当前项时只留当前项并置索引 0', () {
      final q = PlaybackQueue(FakePort('netease'));
      q.replace(<Map<String, Object?>>[song('a'), song('b'), song('c')], song('b'));
      q.clearUpcoming(q.current());
      expect(ids(q), <Object?>['b']);
      expect(q.index, 0);
    });

    test('空或非歌曲当前项时清空队列', () {
      final q = PlaybackQueue(FakePort('netease'));
      q.replace(<Map<String, Object?>>[song('a'), song('b')], song('a'));
      q.clearUpcoming(<String, Object?>{'kind': 'album', 'id': 'x'});
      expect(q.isEmpty, isTrue);
      expect(q.index, -1);
    });

    test('clear 清空条目、索引与历史', () {
      final q = PlaybackQueue(FakePort('netease'), random: math.Random(1));
      q.replace(<Map<String, Object?>>[song('a'), song('b'), song('c')]);
      q.select(1);
      q.clear();
      expect(q.isEmpty, isTrue);
      expect(q.index, -1);
      expect(q.navigate(1, 'all'), -1);
    });
  });

  group('navigate', () {
    test('空队列返回 -1', () {
      expect(PlaybackQueue(FakePort('netease')).navigate(1, 'all'), -1);
    });

    test('one 模式前后项都指向当前索引', () {
      final q = PlaybackQueue(FakePort('netease'));
      q.replace(<Map<String, Object?>>[song('a'), song('b'), song('c')], song('b'));
      expect(q.navigate(1, 'one'), 1);
      expect(q.navigate(-1, 'one'), 1);
      expect(q.index, 1);
      final fresh = PlaybackQueue(FakePort('netease'));
      fresh.replace(<Map<String, Object?>>[song('a')]);
      expect(fresh.navigate(1, 'one'), 0);
    });

    test('off 模式到尾返回 -1，all 模式回绕到队首', () {
      final q = PlaybackQueue(FakePort('netease'));
      q.replace(<Map<String, Object?>>[song('a'), song('b')], song('b'));
      expect(q.navigate(1, 'off'), -1);
      expect(q.index, 1);
      expect(q.navigate(1, 'all'), 0);
      expect(q.index, 0);
      expect(q.navigate(-1, 'all'), 1);
    });

    test('shuffle 前进不会停在当前项且留在范围内', () {
      final q = PlaybackQueue(FakePort('netease'), random: math.Random(7));
      q.replace(<Map<String, Object?>>[song('a'), song('b'), song('c')], song('a'));
      final next = q.navigate(1, 'shuffle');
      expect(next, inInclusiveRange(0, 2));
      expect(next, isNot(0));
      expect(q.index, next);
    });

    test('shuffle 后退沿实际播放顺序回退，耗尽后回落顺序上一项', () {
      final q = PlaybackQueue(FakePort('netease'), random: math.Random(3));
      q.replace(<Map<String, Object?>>[song('a'), song('b'), song('c')]);
      q.select(0);
      q.select(2);
      expect(q.navigate(-1, 'shuffle'), 0);
      expect(q.index, 0);
      // 历史已耗尽：退回普通顺序上一项（回绕到队尾）。
      expect(q.navigate(-1, 'shuffle'), 2);
    });

    test('单曲队列 shuffle 前进不除零', () {
      final q = PlaybackQueue(FakePort('netease'), random: math.Random(5));
      q.replace(<Map<String, Object?>>[song('a')], song('a'));
      expect(q.navigate(1, 'shuffle'), 0);
    });

    test('one 在索引 -1 时返回 0 但不改索引；off 前进从第 0 行开始', () {
      final q = PlaybackQueue(FakePort('netease'));
      q.replace(<Map<String, Object?>>[song('a'), song('b'), song('c')]);
      expect(q.index, -1);
      // Qt PlaybackQueue.cpp:261-263 mode=='one' → return m_index >= 0 ? m_index : 0，
      // 不改 m_index 也不 emit；若写成 _moveTo 会被下面两行发现。
      expect(q.navigate(1, 'one'), 0);
      expect(q.index, -1);
      expect(q.navigate(-1, 'one'), 0);
      expect(q.index, -1);
      // Qt PlaybackQueue.cpp:277 的条件是 selected >= count 且 mode == 'off' 才返回 -1；
      // direction 只取 ±1 时等价于前进越界；index=-1 前进落到第 0 行。
      expect(q.navigate(1, 'off'), 0);
      expect(q.index, 0);
      expect(q.current()['id'], 'a');
    });

    test('随机历史只保留最近 200 条（shuffleHistoryLimit）', () {
      final q = PlaybackQueue(FakePort('netease'), random: math.Random(1));
      q.replace(<Map<String, Object?>>[song('a'), song('b'), song('c'), song('d')], song('a'));
      // 交替 select(1)/select(0) 每次记一条历史，202 次后被截到 200 条（丢掉最早 2 条）。
      for (var i = 0; i < 202; i++) {
        q.select(i.isEven ? 1 : 0);
      }
      expect(q.index, 0);
      // 被保留的 200 条历史刚好在 200 次随机后退里耗尽，每次都落在第 0/1 行之间往复。
      for (var i = 0; i < 200; i++) {
        q.navigate(-1, 'shuffle');
      }
      expect(q.index, 0);
      // 第 201 次历史已空 → 走 fallback：(0-1) 回绕到队尾 3。
      // 若 200 上限失效（历史里还剩最早 2 条），这里会弹出第 1 行而返回 1。
      expect(q.navigate(-1, 'shuffle'), 3);
      expect(q.index, 3);
    });

    test('shuffle 后退跳过已从队列删除的历史条目', () {
      final q = PlaybackQueue(FakePort('netease'), random: math.Random(1));
      q.replace(<Map<String, Object?>>[song('a'), song('b'), song('c'), song('d')], song('a'));
      q.select(2); // 记录第 0 行 a → 历史 [a]
      q.select(3); // 记录第 2 行 c → 历史 [a, c]
      q.select(1); // 记录第 3 行 d → 历史 [a, c, d]；当前第 1 行 b
      expect(ids(q), <Object?>['a', 'b', 'c', 'd']);
      expect(q.remove(3), isTrue); // 删除 d；row 3 > index 1 → index 不变；items = [a, b, c]
      expect(ids(q), <Object?>['a', 'b', 'c']);
      expect(q.index, 1);
      // Qt PlaybackQueue.cpp:240-250：弹出的历史项若已不在队列（d）必须继续弹到 c（第 2 行）。
      // 若只弹一次就回落 fallback：(1-1) → 第 0 行 a，下面三条断言即 RED。
      expect(q.navigate(-1, 'shuffle'), 2);
      expect(q.index, 2);
      expect(q.current()['id'], 'c');
    });

    test('常量与 Qt 一致', () {
      expect(PlaybackQueue.fetchBatchSize, 100);
      expect(PlaybackQueue.shuffleHistoryLimit, 200);
    });
  });

  group('load', () {
    test('合并 ids/known/现有条目并按 ID 顺序发布，缺失才请求', () async {
      final port = FakePort('netease');
      final q = PlaybackQueue(port);
      q.replace(<Map<String, Object?>>[song('a')]);
      final notified = <int>[];
      q.addListener(() => notified.add(q.size));
      await q.load(<String>['a', 'b', 'b', 'c'], <Map<String, Object?>>[song('c')]);
      expect(port.calls, <List<String>>[
        <String>['b'],
      ]);
      expect(ids(q), <Object?>['a', 'b', 'c']);
      expect(q.isLoading, isFalse);
      expect(notified.length, greaterThanOrEqualTo(2));
    });

    test('全部已解析时不请求网络', () async {
      final port = FakePort('netease');
      final q = PlaybackQueue(port);
      await q.load(<String>['a'], <Map<String, Object?>>[song('a')]);
      expect(port.calls, isEmpty);
      expect(ids(q), <Object?>['a']);
    });

    test('超过批次上限时分批请求', () async {
      final port = FakePort('netease');
      final q = PlaybackQueue(port);
      final many = [for (var i = 0; i < 250; i++) 'i$i'];
      await q.load(many, <Map<String, Object?>>[]);
      expect(port.calls.map((c) => c.length).toList(), <int>[100, 100, 50]);
      expect(q.size, 250);
    });

    test('批次失败跳过该批但不产生占位条目', () async {
      final port = FakePort('netease');
      port.handler = (list) async => throw StateError('network');
      final q = PlaybackQueue(port);
      await q.load(<String>['a', 'b'], <Map<String, Object?>>[]);
      expect(q.isEmpty, isTrue);
      expect(q.isLoading, isFalse);
    });

    test('换曲推进代数后迟到批次被丢弃', () async {
      final port = FakePort('netease');
      final gate = Completer<List<Map<String, Object?>>>();
      port.handler = (_) => gate.future;
      final q = PlaybackQueue(port);
      final pending = q.load(<String>['x'], <Map<String, Object?>>[]);
      expect(q.isLoading, isTrue);
      q.clear();
      gate.complete(<Map<String, Object?>>[song('x')]);
      await pending;
      expect(q.isEmpty, isTrue);
      expect(q.isLoading, isFalse);
    });

    test('load 期间保持当前索引选中的歌曲身份', () async {
      final port = FakePort('netease');
      final q = PlaybackQueue(port);
      q.replace(<Map<String, Object?>>[song('a'), song('b')], song('b'));
      await q.load(<String>['a', 'b'], <Map<String, Object?>>[]);
      expect(q.index, 1);
      expect(q.current()['id'], 'b');
    });

    test('队列中的完整曲目补全后不被挤掉', () async {
      final port = FakePort('netease');
      final q = PlaybackQueue(port);
      q.replace(<Map<String, Object?>>[song('keep')], song('keep'));
      await q.load(<String>['keep', 'new'], <Map<String, Object?>>[]);
      expect(ids(q), <Object?>['keep', 'new']);
      expect(q.index, 0);
    });

    test('load 用发布 provider 而非歌曲身份拼补全键', () async {
      final port = FakePort('netease');
      final q = PlaybackQueue(port);
      // 队列里可以持有 provider 与 api.provider 不同的曲目（例如 qq 队列恢复后 api 是 netease）。
      // Qt PlaybackQueue.cpp:293-296/321/337 一律用 m_provider + ':' + id 作 _resolved 键，
      // 只有 publishResolved 的 selected 用 identity。若改成 identity 拼键，
      // 已在队列的当前曲会被误判为 missing 并触发一次网络请求（甚至把队列重建掉）。
      q.replace(<Map<String, Object?>>[song('x', provider: 'qq')], song('x', provider: 'qq'));
      await q.load(<String>['x'], <Map<String, Object?>>[]);
      expect(port.calls, isEmpty);
      expect(ids(q), <Object?>['x']);
      expect(q.index, 0);
      expect(q.current()['provider'], 'qq');
    });

    test('load 中 known 覆盖队列已持有条目的元数据（absorb 顺序 items→known）', () async {
      final port = FakePort('netease');
      final q = PlaybackQueue(port);
      q.replace(<Map<String, Object?>>[
        song('a', extra: <String, Object?>{'title': 'QUEUE'}),
      ], song('a'));
      // Qt PlaybackQueue.cpp:303-321：先 absorb(m_items) 再 absorb(known)，后写覆盖先写，
      // 所以服务端/存档里的新元数据必须赢。交换顺序会把标题永久钉在旧值。
      await q.load(<String>['a'], <Map<String, Object?>>[
        song('a', extra: <String, Object?>{'title': 'KNOWN'}),
      ]);
      expect(port.calls, isEmpty);
      expect(q.items[0]['title'], 'KNOWN');
    });
  });

  group('restore', () {
    test('deferred 条目只进 ID 列表，不立即进队列', () async {
      final port = FakePort('netease');
      final q = PlaybackQueue(port);
      q.restore(<Map<String, Object?>>[
        song('a'),
        <String, Object?>{'kind': 'song', 'id': 'b', 'provider': 'netease', 'deferred': true},
      ], 0, false);
      expect(ids(q), <Object?>['a']);
      expect(q.index, 0);
      expect(port.calls, isEmpty);
    });

    test('hydrate 为真时后台补全 deferred 条目', () async {
      final port = FakePort('netease');
      final q = PlaybackQueue(port);
      q.restore(<Map<String, Object?>>[
        song('a'),
        <String, Object?>{'kind': 'song', 'id': 'b', 'provider': 'netease', 'deferred': true},
      ], 0, true);
      await Future<void>.delayed(Duration.zero);
      expect(ids(q), <Object?>['a', 'b']);
      expect(q.index, 0);
    });

    test('损坏索引不改动选中身份', () async {
      final port = FakePort('netease');
      final q = PlaybackQueue(port);
      q.restore(<Map<String, Object?>>[song('a'), song('b')], 99, true);
      await Future<void>.delayed(Duration.zero);
      expect(ids(q), <Object?>['a', 'b']);
      expect(q.index, -1);
    });

    test('忽略非歌曲与空 ID 存档项', () {
      final q = PlaybackQueue(FakePort('netease'));
      q.restore(<Map<String, Object?>>[
        <String, Object?>{'kind': 'album', 'id': 'x'},
        song(''),
        song('a'),
      ], 0, false);
      expect(ids(q), <Object?>['a']);
    });
  });

  group('toJson / at', () {
    test('toJson 与 items 等值且互不影响', () {
      final q = PlaybackQueue(FakePort('netease'));
      q.replace(<Map<String, Object?>>[song('a')]);
      final json = q.toJson();
      json.add(song('b'));
      json[0]['title'] = 'mutated';
      expect(ids(q), <Object?>['a']);
      expect(q.items[0]['title'], 'Ta');
    });

    test('at 越界返回空对象', () {
      final q = PlaybackQueue(FakePort('netease'));
      q.replace(<Map<String, Object?>>[song('a')]);
      expect(q.at(3), isEmpty);
      expect(q.at(-1), isEmpty);
      expect(q.indexOfId('a'), 0);
      expect(q.indexOfId('zzz'), -1);
    });
  });
}
