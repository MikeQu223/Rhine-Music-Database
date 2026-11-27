/// 播放队列不变量测试（T23-T01）。
///
/// 未执行：本任务禁止 flutter test / dart test / dart analyze / dart run，测试只按源码静态推导。
/// 证据源：lib/domain/player/playback_queue.dart（470 行）与
/// lib/domain/player/music_player.dart（643 行）；Qt 对照 Qt/src/PlaybackQueue.cpp、
/// Qt/src/MusicPlayer.cpp:749-780。
///
/// 覆盖：enqueue 顺序与去重/移动、select/selectTrack 的索引不变量、remove/clearUpcoming/clear
/// 与 current/history 的一致性、load 的批次与失败跳过、以及 sessionState/restoreSessionState
/// 往返后 queue/current/index 的保持。历史只经 'play-history' 偏好回填，sessionState 不含
/// history 键——这是源码现状，测试按现状断言，差异写入 OPS86-A42 报告。
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:rhine_music_database/domain/player/music_player.dart';
import 'package:rhine_music_database/domain/player/playback_queue.dart';

Map<String, Object?> song(
  String id, {
  String provider = 'netease',
  String? title,
  Map<String, Object?> extra = const <String, Object?>{},
}) =>
    <String, Object?>{
      'kind': 'song',
      'id': id,
      'provider': provider,
      'title': title ?? 'T$id',
      ...extra,
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
    return <Map<String, Object?>>[for (final id in ids) song(id, provider: provider)];
  }
}

class FakeMedia implements MediaHostPort {
  Map<String, Object?> state = <String, Object?>{};
  final List<List<Object?>> controls = <List<Object?>>[];
  final List<List<String>> metadata = <List<String>>[];

  @override
  void mediaControl(String action, [double value = 0]) {
    controls.add(<Object?>[action, value]);
  }

  @override
  Map<String, Object?> mediaState() => Map<String, Object?>.of(state);

  @override
  void mediaMetadata(String title, String artist, String album, String cover) {
    metadata.add(<String>[title, artist, album, cover]);
  }
}

class FakePreferences implements PreferencePort {
  FakePreferences([Map<String, String>? initial])
      : values = <String, String>{...?initial};

  final Map<String, String> values;
  final List<List<String>> writes = <List<String>>[];

  @override
  String read(String key) => values[key] ?? '';

  @override
  void write(String key, String value) {
    values[key] = value;
    writes.add(<String>[key, value]);
  }
}

class FakeEngine implements PlaybackEnginePort {
  final List<List<Object?>> calls = <List<Object?>>[];

  @override
  void prepare(Map<String, Object?> track, int generation, {bool reload = false}) {
    calls.add(<Object?>[Map<String, Object?>.of(track), generation, reload]);
  }
}

List<Object?> ids(PlaybackQueue queue) => <Object?>[for (final t in queue.items) t['id']];

List<Object?> currentIds(MusicPlayer player) =>
    <Object?>[for (final t in player.history) t['id']];

MusicPlayer newPlayer({
  FakeMedia? media,
  FakePreferences? preferences,
  FakeEngine? engine,
  QueueMetadataPort? queueApi,
  String Function()? provider,
  math.Random? random,
}) =>
    MusicPlayer(
      media: media ?? FakeMedia(),
      preferences: preferences ?? FakePreferences(),
      engine: engine ?? FakeEngine(),
      queueApi: queueApi,
      provider: provider,
      random: random,
    );

void main() {
  group('identity 与初始状态', () {
    test('identity：provider 缺省 netease，id 缺失为空串（playback_queue.dart:60-67）', () {
      expect(PlaybackQueue.identity(<String, Object?>{'id': 'a'}), 'netease:a');
      expect(PlaybackQueue.identity(<String, Object?>{'id': 'a', 'provider': 'qq'}), 'qq:a');
      expect(PlaybackQueue.identity(<String, Object?>{'id': 'a', 'provider': ''}), ':a');
      expect(PlaybackQueue.identity(<String, Object?>{}), 'netease:');
    });

    test('新队列：空、index=-1、current/at 均为空、isLoading=false（:87-104）', () {
      final q = PlaybackQueue(null);
      expect(q.size, 0);
      expect(q.isEmpty, isTrue);
      expect(q.index, -1);
      expect(q.items, isEmpty);
      expect(q.current(), isEmpty);
      expect(q.at(0), isEmpty);
      expect(q.at(-1), isEmpty);
      expect(q.isLoading, isFalse);
      expect(q.indexOf(song('a')), -1);
      expect(q.indexOfId('a'), -1);
    });

    test('items/at/current 都是深拷贝，外部修改不回写（:87、:97-104）', () {
      final q = PlaybackQueue(null);
      q.replace(<Map<String, Object?>>[song('a')]);
      final list = q.items;
      list.first['title'] = 'hacked';
      q.at(0)['title'] = 'hacked';
      q.current()['title'] = 'hacked';
      expect(q.at(0)['title'], 'Ta');
      expect(q.items.first['title'], 'Ta');
    });
  });

  group('replace / 净化不变量', () {
    test('剔除非 song 与空 id，按 identity 先到先得去重，selected 决定索引（:69-85、:150-156）', () {
      final q = PlaybackQueue(null);
      q.replace(<Map<String, Object?>>[
        song('a'),
        song('b'),
        song('b', title: 'dup'),
        <String, Object?>{'kind': 'album', 'id': 'x'},
        <String, Object?>{'kind': 'song', 'id': ''},
        song('a', provider: 'qq'),
      ], song('b'));
      expect(ids(q), <Object?>['a', 'b', 'a']);
      expect(q.index, 1);
      expect(q.current()['id'], 'b');
      expect(q.at(1)['title'], 'Tb');
      expect(q.size, 3);
    });

    test('selected 不在（或为空）→ index=-1，current 为空（:154-155）', () {
      final q = PlaybackQueue(null);
      q.replace(<Map<String, Object?>>[song('a')], song('zzz'));
      expect(q.index, -1);
      expect(q.current(), isEmpty);
      q.replace(<Map<String, Object?>>[song('a')], <String, Object?>{});
      expect(q.index, -1);
    });

    test('replace 清空随机历史：旧首曲不再被 shuffle 后退取回（:152-153、:287-297）', () {
      final q = PlaybackQueue(null);
      q.replace(<Map<String, Object?>>[song('a'), song('b'), song('c')]);
      q.select(0);
      q.select(2); // 旧当前 a 进入历史（history=[a]）
      q.replace(<Map<String, Object?>>[song('a'), song('b'), song('c')]);
      expect(q.index, -1);
      q.select(2); // 前一个 index 为 -1，不记历史
      // 历史已清 → 顺序前一首（1）；若历史残留会取回 a（0）
      expect(q.navigate(-1, 'shuffle'), 1);
      expect(q.current()['id'], 'b');
    });

    test('replace 取消 in-flight load，迟到批次被 generation 丢弃（:125-132、:426-437）', () async {
      final gate = Completer<List<Map<String, Object?>>>();
      final port = FakePort('netease', handler: (List<String> _) => gate.future);
      final q = PlaybackQueue(port);
      final loading = q.load(<String>['a'], <Map<String, Object?>>[]);
      expect(q.isLoading, isTrue);
      q.replace(<Map<String, Object?>>[song('b')]);
      gate.complete(<Map<String, Object?>>[song('a')]);
      await loading;
      expect(ids(q), <Object?>['b']);
      expect(q.isLoading, isFalse);
    });

    test('syncSnapshot：row 合法则选中、越界为 -1，且不发信号（:158-166）', () {
      final q = PlaybackQueue(null);
      var emitted = 0;
      q.addListener(() => emitted += 1);
      q.syncSnapshot(<Map<String, Object?>>[song('a'), song('b')], 1);
      expect(ids(q), <Object?>['a', 'b']);
      expect(q.index, 1);
      expect(q.current()['id'], 'b');
      q.syncSnapshot(<Map<String, Object?>>[song('a')], 5);
      expect(q.index, -1);
      expect(emitted, 0);
    });
  });

  group('enqueue 顺序与去重/移动', () {
    test('next=false 追加队尾、返回 true、恰好发一次信号（:192-215）', () {
      final q = PlaybackQueue(null);
      var emitted = 0;
      q.addListener(() => emitted += 1);
      q.replace(<Map<String, Object?>>[song('a')], song('a'));
      expect(q.enqueue(song('b')), isTrue);
      expect(ids(q), <Object?>['a', 'b']);
      expect(q.index, 0);
      expect(emitted, 2); // replace 一次 + enqueue 一次
    });

    test('next=true 插到当前之后；index=-1 时插到 0（:211）', () {
      final q = PlaybackQueue(null);
      q.replace(<Map<String, Object?>>[song('a'), song('b')], song('a'));
      expect(q.enqueue(song('x'), next: true), isTrue);
      expect(ids(q), <Object?>['a', 'x', 'b']);
      expect(q.index, 0);

      final empty = PlaybackQueue(null);
      expect(empty.enqueue(song('z'), next: true), isTrue);
      expect(ids(empty), <Object?>['z']);
      expect(empty.index, -1);
    });

    test('同 identity 非当前项：先删除旧行再追加队尾，index 随删除前移（:201-213）', () {
      final q = PlaybackQueue(null);
      q.replace(<Map<String, Object?>>[song('a'), song('b'), song('c'), song('d')], song('c'));
      expect(q.index, 2);
      expect(q.enqueue(song('a', title: 'A2')), isTrue);
      expect(ids(q), <Object?>['b', 'c', 'd', 'a']);
      expect(q.index, 1);
      expect(q.current()['id'], 'c');
      expect(q.at(3)['title'], 'A2');
    });

    test('同 identity + next=true：删除旧行后插到调整后的当前项之后（:202-212）', () {
      final q = PlaybackQueue(null);
      q.replace(<Map<String, Object?>>[song('a'), song('b'), song('c'), song('d')], song('c'));
      expect(q.enqueue(song('a'), next: true), isTrue);
      expect(ids(q), <Object?>['b', 'c', 'a', 'd']);
      expect(q.index, 1);
      expect(q.current()['id'], 'c');
    });

    test('非 song / 空 id 一律 false，且不改变队列（:193-195）', () {
      final q = PlaybackQueue(null);
      q.replace(<Map<String, Object?>>[song('a')], song('a'));
      expect(q.enqueue(<String, Object?>{'kind': 'album', 'id': 'x'}), isFalse);
      expect(q.enqueue(<String, Object?>{'kind': 'song', 'id': ''}), isFalse);
      expect(q.enqueue(<String, Object?>{'kind': 'song'}), isFalse);
      expect(ids(q), <Object?>['a']);
    });

    test('provider 隔离只在有 api 时生效：local 队列拒 netease，反之亦然（:196-200）', () {
      final localQueue = PlaybackQueue(FakePort('local'));
      expect(localQueue.enqueue(song('a', provider: 'netease')), isFalse);
      expect(localQueue.enqueue(song('b', provider: 'local')), isTrue);

      final neteaseQueue = PlaybackQueue(FakePort('netease'));
      expect(neteaseQueue.enqueue(song('c', provider: 'local')), isFalse);
      expect(neteaseQueue.enqueue(song('d', provider: 'netease')), isTrue);

      final noApi = PlaybackQueue(null);
      expect(noApi.enqueue(song('e', provider: 'local')), isTrue);
    });
  });

  group('select / selectTrack / updateCurrent', () {
    test('select 越界或同行是静默 no-op（:168-170、:275-278）', () {
      final q = PlaybackQueue(null);
      q.replace(<Map<String, Object?>>[song('a'), song('b')], song('a'));
      var emitted = 0;
      q.addListener(() => emitted += 1);
      q.select(0);
      q.select(-1);
      q.select(2);
      expect(q.index, 0);
      expect(emitted, 0);
    });

    test('select 合法行更新 index 并记住旧当前（:275-285）', () {
      final q = PlaybackQueue(null);
      q.replace(<Map<String, Object?>>[song('a'), song('b'), song('c')]);
      var emitted = 0;
      q.addListener(() => emitted += 1);
      q.select(1);
      expect(q.index, 1);
      expect(emitted, 1);
      q.select(2);
      expect(q.current()['id'], 'c');
      // select(2) 时旧当前 b 被记入历史：shuffle 后退取回 b
      expect(q.navigate(-1, 'shuffle'), 1);
    });

    test('selectTrack：已在队列则移动索引，不在则追加并选中（:172-190）', () {
      final q = PlaybackQueue(null);
      q.replace(<Map<String, Object?>>[song('a'), song('b')], song('a'));
      q.selectTrack(song('b', title: 'B-new'));
      expect(q.index, 1);
      expect(ids(q), <Object?>['a', 'b']);
      expect(q.at(1)['title'], 'Tb'); // 已在队列时不替换元数据

      q.selectTrack(song('c'));
      expect(ids(q), <Object?>['a', 'b', 'c']);
      expect(q.index, 2);
      expect(q.current()['id'], 'c');
    });

    test('selectTrack 对非 song / 空 id 不做任何事（:183）', () {
      final q = PlaybackQueue(null);
      q.replace(<Map<String, Object?>>[song('a')], song('a'));
      q.selectTrack(<String, Object?>{'kind': 'album', 'id': 'x'});
      q.selectTrack(<String, Object?>{'kind': 'song', 'id': ''});
      expect(ids(q), <Object?>['a']);
      expect(q.index, 0);
      expect(q.current()['id'], 'a');
    });

    test('updateCurrent 只替换同 identity 的当前项（:229-236）', () {
      final q = PlaybackQueue(null);
      q.replace(<Map<String, Object?>>[song('a'), song('b')], song('b'));
      var emitted = 0;
      q.addListener(() => emitted += 1);
      q.updateCurrent(song('a', title: 'A2'));
      expect(q.at(0)['title'], 'Ta');
      expect(emitted, 0);
      q.updateCurrent(song('b', title: 'B2'));
      expect(q.at(1)['title'], 'B2');
      expect(emitted, 1);
      expect(q.index, 1);
    });
  });

  group('remove / clearUpcoming / clear 语义', () {
    test('remove 当前行被拒绝，current 与 index 不变（:217-227）', () {
      final q = PlaybackQueue(null);
      q.replace(<Map<String, Object?>>[song('a'), song('b')], song('a'));
      var emitted = 0;
      q.addListener(() => emitted += 1);
      expect(q.remove(0), isFalse);
      expect(ids(q), <Object?>['a', 'b']);
      expect(q.index, 0);
      expect(emitted, 0);
    });

    test('remove 当前之前的行：成功且 index 前移，current 仍是同一首（:221-224）', () {
      final q = PlaybackQueue(null);
      q.replace(<Map<String, Object?>>[song('a'), song('b'), song('c')], song('b'));
      expect(q.remove(0), isTrue);
      expect(ids(q), <Object?>['b', 'c']);
      expect(q.index, 0);
      expect(q.current()['id'], 'b');
    });

    test('remove 当前之后的行：成功且 index 不变；越界为 false（:218-223）', () {
      final q = PlaybackQueue(null);
      q.replace(<Map<String, Object?>>[song('a'), song('b'), song('c')], song('b'));
      expect(q.remove(2), isTrue);
      expect(ids(q), <Object?>['a', 'b']);
      expect(q.index, 1);
      expect(q.remove(2), isFalse);
      expect(q.remove(-1), isFalse);
    });

    test('clearUpcoming：合法 current 只留该项、index=0、清空历史（:238-250）', () {
      final q = PlaybackQueue(null);
      q.replace(<Map<String, Object?>>[song('a'), song('b'), song('c')], song('b'));
      q.select(2); // history=[b]
      q.clearUpcoming(song('b', title: 'B2'));
      expect(ids(q), <Object?>['b']);
      expect(q.size, 1);
      expect(q.index, 0);
      expect(q.current()['title'], 'B2');
      // 历史已清：无历史可取时 shuffle 后退回到顺序前一首（单曲环绕 0）
      expect(q.navigate(-1, 'shuffle'), 0);
    });

    test('clearUpcoming：空或非 song current → 全清、index=-1（:241-243）', () {
      final q = PlaybackQueue(null);
      q.replace(<Map<String, Object?>>[song('a'), song('b')], song('a'));
      q.clearUpcoming(<String, Object?>{});
      expect(q.isEmpty, isTrue);
      expect(q.index, -1);

      q.replace(<Map<String, Object?>>[song('a')], song('a'));
      q.clearUpcoming(<String, Object?>{'kind': 'album', 'id': 'a'});
      expect(q.isEmpty, isTrue);
      expect(q.index, -1);
    });

    test('clear：清空队列与历史，current 不再存在（:253-259）', () {
      final q = PlaybackQueue(null);
      q.replace(<Map<String, Object?>>[song('a'), song('b')], song('a'));
      q.select(1);
      q.clear();
      expect(q.isEmpty, isTrue);
      expect(q.size, 0);
      expect(q.index, -1);
      expect(q.current(), isEmpty);
      expect(q.at(0), isEmpty);
      expect(q.navigate(1, 'all'), -1);
    });
  });

  group('navigate 不变量', () {
    test('空队列返回 -1（:305-307）', () {
      expect(PlaybackQueue(null).navigate(1, 'all'), -1);
      expect(PlaybackQueue(null).navigate(-1, 'off'), -1);
    });

    test('mode=one 返回当前索引且不移动；index=-1 时返回 0 但仍不移动（:308-311）', () {
      final q = PlaybackQueue(null);
      q.replace(<Map<String, Object?>>[song('a'), song('b')], song('b'));
      expect(q.navigate(1, 'one'), 1);
      expect(q.index, 1);
      expect(q.navigate(-1, 'one'), 1);

      final untouched = PlaybackQueue(null);
      untouched.replace(<Map<String, Object?>>[song('a'), song('b')]);
      expect(untouched.index, -1);
      expect(untouched.navigate(-1, 'one'), 0);
      expect(untouched.index, -1);
    });

    test('mode=off：末尾再前进返回 -1 且不移动；中间正常前进（:325-327）', () {
      final q = PlaybackQueue(null);
      q.replace(<Map<String, Object?>>[song('a'), song('b')], song('b'));
      var emitted = 0;
      q.addListener(() => emitted += 1);
      expect(q.navigate(1, 'off'), -1);
      expect(q.index, 1);
      expect(emitted, 0);

      q.select(0);
      expect(q.navigate(1, 'off'), 1);
      expect(q.current()['id'], 'b');
    });

    test('mode=all/all 之外：末尾前进环绕到 0，首行后退环绕到末行（:328-329）', () {
      final q = PlaybackQueue(null);
      q.replace(<Map<String, Object?>>[song('a'), song('b'), song('c')], song('c'));
      expect(q.navigate(1, 'all'), 0);
      expect(q.current()['id'], 'a');
      expect(q.navigate(-1, 'all'), 2);
      expect(q.current()['id'], 'c');
    });

    test('shuffle 前进永不选中当前行（count>1 时 ; :322-324）', () {
      final q = PlaybackQueue(null, random: math.Random(9));
      q.replace(<Map<String, Object?>>[song('a'), song('b'), song('c')], song('a'));
      for (var round = 0; round < 30; round++) {
        final before = q.index;
        final selected = q.navigate(1, 'shuffle');
        expect(selected, isNot(before));
        expect(selected, inInclusiveRange(0, 2));
        expect(q.index, selected);
      }
    });

    test('shuffle 后退按 history LIFO 回退，耗尽后回落到顺序前一首（:312-319）', () {
      final q = PlaybackQueue(null);
      q.replace(<Map<String, Object?>>[song('a'), song('b'), song('c')], song('a'));
      q.select(1); // history=[a]
      q.select(2); // history=[a, b]
      expect(q.navigate(-1, 'shuffle'), 1);
      expect(q.current()['id'], 'b');
      expect(q.navigate(-1, 'shuffle'), 0);
      expect(q.current()['id'], 'a');
      // 历史耗尽：0-1 环绕到末行
      expect(q.navigate(-1, 'shuffle'), 2);
      expect(q.current()['id'], 'c');
    });

    test('单曲队列在任何 mode 下都停在 0（:320-330）', () {
      final q = PlaybackQueue(null);
      q.replace(<Map<String, Object?>>[song('a')], song('a'));
      expect(q.navigate(1, 'all'), 0);
      expect(q.navigate(-1, 'all'), 0);
      expect(q.navigate(1, 'shuffle'), 0);
      expect(q.navigate(-1, 'shuffle'), 0);
      expect(q.navigate(1, 'one'), 0);
      expect(q.index, 0);
    });
  });

  group('load / restore 补全语义', () {
    test('load 保持 ids 顺序、去重、跳过空 id，known 直接补齐（:334-382）', () async {
      final port = FakePort('netease');
      final q = PlaybackQueue(port);
      await q.load(<String>['a', '', 'b', 'a'], <Map<String, Object?>>[song('b')]);
      expect(ids(q), <Object?>['a', 'b']);
      expect(port.calls, <List<String>>[
        <String>['a'],
      ]);
      expect(q.isLoading, isFalse);
      expect(q.index, -1);
    });

    test('load 按 fetchBatchSize=100 分批，250 个 id → 100/100/50（:28、:408-445）', () async {
      final port = FakePort('netease');
      final q = PlaybackQueue(port);
      await q.load(<String>[for (var i = 0; i < 250; i++) 'id$i'], <Map<String, Object?>>[]);
      expect(port.calls.length, 3);
      expect(port.calls[0].length, 100);
      expect(port.calls[1].length, 100);
      expect(port.calls[2].length, 50);
      expect(q.size, 250);
      expect(q.items.first['id'], 'id0');
      expect(q.items.last['id'], 'id249');
      expect(q.isLoading, isFalse);
    });

    test('load 失败批次整批跳过，不产生占位条目（:423-433）', () async {
      final port = FakePort('netease', handler: (List<String> batch) async {
        if (batch.first == 'id100') {
          throw StateError('network down');
        }
        return <Map<String, Object?>>[for (final id in batch) song(id)];
      });
      final q = PlaybackQueue(port);
      await q.load(<String>[for (var i = 0; i < 150; i++) 'id$i'], <Map<String, Object?>>[]);
      expect(port.calls.length, 2);
      expect(q.size, 100);
      expect(q.items.first['id'], 'id0');
      expect(q.items.last['id'], 'id99');
      expect(q.indexOfId('id100'), -1);
      expect(q.isLoading, isFalse);
    });

    test('restore：只有完整曲目立即入队，deferred 项不占位（:447-467）', () {
      final q = PlaybackQueue(null);
      q.restore(
        <Map<String, Object?>>[
          song('a'),
          <String, Object?>{'kind': 'song', 'id': 'd', 'deferred': true},
          song('c'),
        ],
        0,
        false,
      );
      expect(ids(q), <Object?>['a', 'c']);
      expect(q.index, 0);
      expect(q.current()['id'], 'a');
      expect(q.indexOfId('d'), -1);
    });

    test('restore：savedIndex 指向 deferred 时 index=-1（:461-463）', () {
      final q = PlaybackQueue(null);
      q.restore(
        <Map<String, Object?>>[
          song('a'),
          <String, Object?>{'kind': 'song', 'id': 'd', 'deferred': true},
          song('c'),
        ],
        1,
        false,
      );
      expect(ids(q), <Object?>['a', 'c']);
      expect(q.index, -1);
    });

    test('restore(hydrate:true)：deferred 经 api 补全后按原顺序进入队列（:464-466）', () async {
      final port = FakePort('netease');
      final q = PlaybackQueue(port);
      q.restore(
        <Map<String, Object?>>[
          song('a'),
          <String, Object?>{'kind': 'song', 'id': 'd', 'deferred': true},
          song('c'),
        ],
        0,
        true,
      );
      expect(q.isLoading, isTrue);
      await Future<void>.delayed(Duration.zero);
      expect(port.calls, <List<String>>[
        <String>['d'],
      ]);
      expect(ids(q), <Object?>['a', 'd', 'c']);
      expect(q.index, 0);
      expect(q.current()['id'], 'a');
      expect(q.isLoading, isFalse);
    });
  });

  group('play 与队列的交互', () {
    test('play(source) 替换队列，play 选中当前曲目（music_player.dart:350-383）', () {
      final player = newPlayer();
      player.play(song('b', title: 'B'), source: <Map<String, Object?>>[song('a'), song('b'), song('c')]);
      expect(ids(player.queue), <Object?>['a', 'b', 'c']);
      expect(player.queue.index, 1);
      expect(player.current['id'], 'b');
      expect(player.loading, isTrue);
      expect(player.status, '正在准备：B');
    });

    test('play(queueIndex) 覆盖 selectTrack 选中的行（:369-371）', () {
      final player = newPlayer();
      player.play(
        song('c'),
        source: <Map<String, Object?>>[song('a'), song('b'), song('c')],
        queueIndex: 0,
      );
      expect(player.queue.index, 0);
      expect(player.current['id'], 'c');
      expect(player.queue.current()['id'], 'a');
    });

    test('play 拒绝非 song 与跨来源曲目（:357-361）', () {
      final engine = FakeEngine();
      final player = newPlayer(engine: engine, provider: () => 'local');
      player.play(song('a', provider: 'netease'));
      expect(player.current, isEmpty);
      expect(engine.calls, isEmpty);
      player.play(<String, Object?>{'kind': 'album', 'id': 'x', 'provider': 'local'});
      expect(player.current, isEmpty);
      player.play(song('b', provider: 'local'));
      expect(player.current['id'], 'b');
      expect(engine.calls.length, 1);
    });

    test('enqueue 只做 kind 守卫，其余委托队列（:338-343）', () {
      final player = newPlayer(queueApi: FakePort('netease'));
      expect(player.enqueue(<String, Object?>{'kind': 'album', 'id': 'x'}), isFalse);
      expect(player.enqueue(song('a')), isTrue);
      expect(ids(player.queue), <Object?>['a']);
      expect(player.enqueue(song('b', provider: 'local')), isFalse);
    });

    test('next 按 mode 推进队列并播放目标行（:478-489）', () {
      final engine = FakeEngine();
      final player = newPlayer(engine: engine);
      player.play(song('a'), source: <Map<String, Object?>>[song('a'), song('b')]);
      player.playbackStarted(generation: 1);
      player.next();
      expect(player.queue.index, 1);
      expect(player.current['id'], 'b');
      expect(player.loading, isTrue);
      expect(engine.calls.length, 2);
      expect(player.status, '正在准备：Tb');
    });

    test('next 在 off 末尾给出「队列已播放完」且不换曲（:483-487）', () {
      final player = newPlayer();
      player.play(song('b'), source: <Map<String, Object?>>[song('a'), song('b')]);
      player.playbackStarted(generation: 1);
      player.setMode('off');
      player.next();
      expect(player.status, '队列已播放完');
      expect(player.current['id'], 'b');
      expect(player.queue.index, 1);
    });

    test('stop 清空队列与 current，但保留 history 与偏好（:503-518）', () {
      final media = FakeMedia();
      final prefs = FakePreferences();
      final player = newPlayer(media: media, preferences: prefs);
      player.play(song('a'), source: <Map<String, Object?>>[song('a'), song('b')]);
      player.playbackStarted(generation: 1);
      final savedHistory = prefs.values['play-history'];
      player.stop();
      expect(player.queue.isEmpty, isTrue);
      expect(player.current, isEmpty);
      expect(player.loading, isFalse);
      expect(player.status, '');
      expect(player.state, <String, Object?>{
        'playing': false,
        'position': 0.0,
        'duration': 0.0,
        'volume': 0.7,
        'seekable': false,
      });
      expect(media.controls.last, <Object?>['stop', 0.0]);
      expect(media.metadata.last, <String>['', '', '', '']);
      expect(currentIds(player), <Object?>['a']);
      expect(prefs.values['play-history'], savedHistory);
    });
  });

  group('sessionState / restoreSessionState 往返', () {
    test('sessionState 恰好 7 键，queue/current/index 与播放器一致（:540-558）', () {
      final player = newPlayer();
      player.play(song('b'), source: <Map<String, Object?>>[song('a'), song('b'), song('c')]);
      final session = player.sessionState();
      expect(session.keys.toSet(), <String>{
        'current',
        'queue',
        'index',
        'mode',
        'position',
        'requested',
        'preview',
      });
      expect(session.containsKey('history'), isFalse);
      expect((session['current'] as Map<String, Object?>)['id'], 'b');
      expect(session['index'], 1);
      expect(session['mode'], 'all');
      expect(session['position'], 0.0);
      expect(session['requested'], isTrue); // loading=true
      expect(session['preview'], isFalse);
      expect(<Object?>[
        for (final item in session['queue'] as List<Object?>) (item as Map<String, Object?>)['id'],
      ], <Object?>['a', 'b', 'c']);
    });

    test('往返后 queue/current/index 保持；history 经 play-history 偏好回填（:563-583）', () {
      final prefs = FakePreferences();
      final first = newPlayer(preferences: prefs, queueApi: FakePort('netease'));
      first.play(song('b'), source: <Map<String, Object?>>[song('a'), song('b'), song('c')]);
      first.playbackStarted(generation: 1);
      final session = first.sessionState();
      final expectedHistory = first.history;

      final second = newPlayer(preferences: prefs, queueApi: FakePort('netease'));
      second.restoreSessionState(session);
      expect(ids(second.queue), <Object?>['a', 'b', 'c']);
      expect(second.queue.index, 1);
      expect(second.queue.current()['id'], 'b');
      expect(second.current['id'], 'b');
      expect(second.history, expectedHistory);
      expect(second.loading, isTrue); // play() 进入准备态
      expect(second.status, '正在准备：Tb');
      expect(second.mode, 'all');
    });

    test('无 play-history 偏好时 history 不随 sessionState 往返（空）', () {
      final first = newPlayer();
      first.play(song('b'), source: <Map<String, Object?>>[song('a'), song('b')]);
      first.playbackStarted(generation: 1);
      final session = first.sessionState();
      final second = newPlayer();
      second.restoreSessionState(session);
      expect(second.history, isEmpty);
      expect(second.current['id'], 'b');
    });

    test('position 门：缺失、负数、非有限、字符串、>1e12 都整体放弃（:564-567）', () {
      for (final bad in <Object?>[null, -1, -0.5, double.nan, double.infinity, '500', 1e12 + 1]) {
        final player = newPlayer();
        player.setMode('shuffle');
        final saved = <String, Object?>{
          'position': ?bad,
          'mode': 'one',
          'current': song('a'),
          'queue': <Object?>[song('a')],
          'index': 0,
        };
        player.restoreSessionState(saved);
        expect(player.mode, 'shuffle', reason: 'position=$bad');
        expect(player.current, isEmpty, reason: 'position=$bad');
        expect(player.queue.isEmpty, isTrue, reason: 'position=$bad');
      }
    });

    test('mode 先于 current 判定：非法 mode 归 all，非 song current 直接返回（:568-580）', () {
      final player = newPlayer();
      player.restoreSessionState(<String, Object?>{
        'position': 0.0,
        'mode': 'bogus',
        'current': <String, Object?>{'kind': 'album', 'id': 'x'},
        'queue': <Object?>[song('a')],
        'index': 0,
      });
      expect(player.mode, 'all');
      expect(player.current, isEmpty);
      expect(player.queue.isEmpty, isTrue);

      player.restoreSessionState(<String, Object?>{
        'position': 0.0,
        'mode': 'one',
        'current': <String, Object?>{'kind': 'album', 'id': 'x'},
        'queue': <Object?>[song('a')],
        'index': 0,
      });
      expect(player.mode, 'one');
    });

    test('current 为空：只恢复队列，不进入 play/prepare（:571-575）', () {
      final engine = FakeEngine();
      final player = newPlayer(engine: engine);
      player.restoreSessionState(<String, Object?>{
        'position': 0.0,
        'mode': 'shuffle',
        'current': <String, Object?>{},
        'queue': <Object?>[song('a'), song('b')],
        'index': 1,
      });
      expect(player.mode, 'shuffle');
      expect(ids(player.queue), <Object?>['a', 'b']);
      expect(player.queue.index, 1);
      expect(player.current, isEmpty);
      expect(player.loading, isFalse);
      expect(engine.calls, isEmpty);
    });

    test('current 的 provider 不匹配时整体放弃，队列不恢复（:577-580）', () {
      final player = newPlayer();
      player.restoreSessionState(<String, Object?>{
        'position': 0.0,
        'mode': 'off',
        'current': song('a', provider: 'qq'),
        'queue': <Object?>[song('a', provider: 'qq')],
        'index': 0,
      });
      expect(player.mode, 'off');
      expect(player.current, isEmpty);
      expect(player.queue.isEmpty, isTrue);
    });
  });

  group('tick 的断点恢复定位', () {
    test('待恢复位置在 seekable 且非 loading 时换算成秒并下发 seek（:401-408）', () {
      final media = FakeMedia();
      final player = newPlayer(media: media);
      player.play(
        song('a'),
        resume: <String, Object?>{'position': 3000.0, 'requested': false},
      );
      player.fail('prepare failed');
      expect(player.failed, isTrue);
      media.state = <String, Object?>{'seekable': true, 'duration': 5000.0, 'position': 100.0};
      player.tick(0, force: true);
      expect(media.controls, contains(<Object?>['seek', 3000.0]));
      expect(media.controls, contains(<Object?>['pause', 0.0]));
      expect(player.failed, isTrue);
      // 第二次 tick 不再重复 seek
      final seeks = media.controls.where((c) => c[0] == 'seek').length;
      player.tick(0.2, force: true);
      expect(media.controls.where((c) => c[0] == 'seek').length, seeks);
    });

    test('seekable=false 时保留待恢复位置，不提前消费（:401）', () {
      final media = FakeMedia();
      final player = newPlayer(media: media);
      player.play(song('a'), resume: <String, Object?>{'position': 3000.0});
      player.fail('prepare failed');
      media.state = <String, Object?>{'seekable': false, 'duration': 5000.0};
      player.tick(0, force: true);
      expect(media.controls.where((c) => c[0] == 'seek'), isEmpty);
      // 待恢复位置仍在：sessionState 仍报告它
      expect(player.sessionState()['position'], 3000.0);
    });
  });
}
