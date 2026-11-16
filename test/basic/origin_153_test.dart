import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rhine_music_database/basic/basic_models.dart';
import 'package:rhine_music_database/basic/qt_scene_view.dart';

/// ORIGIN-LIFECYCLE-153 的可证伪契约（Dart 侧）。
///
/// 这一组测试针对的是**已确认的真实缺陷**，不是假想的边界：
///
/// * 生产者 A 的快照已经 apply，生产者 B 的快照排队在 Qt 事件队列里；A 的输入/回执在
///   这里被复算一次，必须仍然按 **A 的 (viewId, ctx)** 判定，不能被 B 的新代次贴标签。
///   旧实现读的是"当前全局 origin"，于是迟到的 A 回执被当成 B 的动作下发，Qt 用新标签
///   把旧位置当成"当前窗口"解释——画面跳、惯性断。
/// * 集合身份一开始只记 `length:first:last`，中间两条对调（条数、首末都不变）不可见，
///   代次不递增，旧输入照样通过门禁。这里是那条缺陷的反例。
/// * Qt 的 `QtMultimediaUtils` 与场景生命周期不在 Dart 侧，本文件不假装验证。
SirenSong _song(String id) => SirenSong(
      id: id,
      title: 'song-$id',
      artist: 'artist',
      album: 'album',
      albumId: 'album-$id',
      cover: '',
      sourceUrl: '',
      lyricUrl: '',
      durationMs: 0,
    );

BasicViewState _state({
  List<SirenSong> songs = const <SirenSong>[],
  List<List<BasicListItem>> laneItems = const <List<BasicListItem>>[],
  double? listPosition,
  bool playing = false,
}) =>
    BasicViewState(
      phase: BasicPhase.library,
      songs: songs,
      laneItems: laneItems,
      listPosition: listPosition,
      playing: playing,
    );

Map<String, Object?> _decode(String snapshot) =>
    jsonDecode(snapshot) as Map<String, Object?>;

BasicListItem _item(String id, {int index = 0}) => BasicListItem(
      title: 'song-$id',
      kind: 'song',
      index: index,
      id: id,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('qtSceneNextContext：只前进，不回头', () {
    test('未登记 → 1，之后每次 +1', () {
      expect(qtSceneNextContext(0), 1);
      expect(qtSceneNextContext(1), 2);
      expect(qtSceneNextContext(41), 42);
    });

    test('代次单调递增，且不会出现 0 或负数（0 是"未登记"专用）', () {
      int ctx = 0;
      final List<int> seen = <int>[];
      for (int i = 0; i < 8; i += 1) {
        ctx = qtSceneNextContext(ctx);
        seen.add(ctx);
      }
      expect(seen, <int>[1, 2, 3, 4, 5, 6, 7, 8]);
      expect(seen.every((int value) => value > 0), isTrue);
    });
  });

  group('集合身份指纹：有序、按列、可复现', () {
    test('空列有稳定身份，不与任何真实列相等', () {
      expect(qtSceneLaneIdentity(const <BasicListItem>[]), '-');
      expect(
        qtSceneLaneIdentity(const <BasicListItem>[]),
        isNot(qtSceneLaneIdentity(<BasicListItem>[_item('a')])),
      );
    });

    test('条目之间必须有分隔，拼接不可冒充', () {
      // 若指纹直接把 key 连起来（'ab'+'c' 与 'a'+'bc'），两份不同的集合会撞成同一身份，
      // 迟到的旧输入就会被当成新集合的输入。
      const BasicListItem ab = BasicListItem(title: 'ab', kind: 'song', index: 0, id: 'ab');
      const BasicListItem c = BasicListItem(title: 'c', kind: 'song', index: 1, id: 'c');
      const BasicListItem a = BasicListItem(title: 'a', kind: 'song', index: 0, id: 'a');
      const BasicListItem bc = BasicListItem(title: 'bc', kind: 'song', index: 1, id: 'bc');
      expect(
        qtSceneLaneIdentity(const <BasicListItem>[ab, c]),
        isNot(qtSceneLaneIdentity(const <BasicListItem>[a, bc])),
      );
    });

    test('相邻对调（条数、首末都不变）改变身份', () {
      final BasicListItem a = _item('a');
      final BasicListItem b = _item('b');
      final BasicListItem c = _item('c');
      final BasicListItem d = _item('d');
      // 只对调中间两项：条数、首、末都不变，旧指纹 `length:first:last` 才真的看不见。
      // （三项时对调的是最后两项，末项会变，那样就证明不了缺陷。）
      final String before = qtSceneLaneIdentity(<BasicListItem>[a, b, c, d]);
      final String after = qtSceneLaneIdentity(<BasicListItem>[a, c, b, d]);
      expect(after, isNot(before));
      // 旧实现 `length:first:last` 在这两份集合上完全相同——这正是缺陷本身：
      String oldForm(List<BasicListItem> lane) =>
          '${lane.length}:${lane.first.key}:${lane.last.key}';
      expect(
        oldForm(<BasicListItem>[a, b, c, d]),
        oldForm(<BasicListItem>[a, c, b, d]),
        reason: '旧指纹看不见这种变化，所以代次不递增',
      );
    });

    test('同长度不同集合身份不同，不同长度身份不同', () {
      expect(
        qtSceneLaneIdentity(<BasicListItem>[_item('a'), _item('b')]),
        isNot(qtSceneLaneIdentity(<BasicListItem>[_item('a'), _item('z')])),
      );
      expect(
        qtSceneLaneIdentity(<BasicListItem>[_item('a')]),
        isNot(qtSceneLaneIdentity(<BasicListItem>[_item('a'), _item('a', index: 1)])),
      );
    });
  });

  group('QtSceneIdentityTracker：按列增量，与纯函数同义', () {
    test('首次调用与纯函数一致', () {
      final BasicViewState state = _state(
        songs: <SirenSong>[_song('a')],
        laneItems: <List<BasicListItem>>[
          <BasicListItem>[_item('a')],
        ],
      );
      final QtSceneIdentityTracker tracker = QtSceneIdentityTracker();
      expect(tracker.signature(state), qtSceneIdentitySignature(state));
    });

    test('只有变化的列重新计算，未变列沿用缓存身份', () {
      final BasicListItem a = _item('a');
      final BasicListItem b = _item('b');
      final List<BasicListItem> lane0 = <BasicListItem>[a];
      final List<BasicListItem> lane1 = <BasicListItem>[b];
      final QtSceneIdentityTracker tracker = QtSceneIdentityTracker();
      final String first = tracker.identityOf(0, lane0);
      final String second = tracker.identityOf(1, lane1);
      // 同一个实例再问：命中缓存，值不变。
      expect(tracker.identityOf(0, lane0), first);
      expect(tracker.identityOf(1, lane1), second);
      // 第 0 列换了新实例：第 0 列身份变化，第 1 列不受影响。
      final List<BasicListItem> lane0b = <BasicListItem>[a, _item('c', index: 1)];
      expect(tracker.identityOf(0, lane0b), isNot(first));
      expect(tracker.identityOf(1, lane1), second);
      // reset 之后回到纯函数结果，不会保留旧缓存。
      tracker.reset();
      expect(tracker.identityOf(0, lane0b), qtSceneLaneIdentity(lane0b));
    });

    test('内容相同、实例不同 → 身份相同（重建列表不等于换集合）', () {
      final List<BasicListItem> first = <BasicListItem>[_item('a'), _item('b', index: 1)];
      final List<BasicListItem> rebuilt = <BasicListItem>[_item('a'), _item('b', index: 1)];
      final QtSceneIdentityTracker tracker = QtSceneIdentityTracker();
      expect(tracker.identityOf(0, first), tracker.identityOf(0, rebuilt));
    });
  });

  group('QtSceneActions：迟到动作按自己的 origin 判定，不被新代次贴标签', () {
    tearDown(QtSceneActions.resetForTest);

    test('A 的快照之后 B 又 apply：A 的迟到动作带 A 的 ctx → 仍归 A，不被当成 B', () async {
      final List<String> a = <String>[];
      final List<String> b = <String>[];
      QtSceneActions.register(7, a.add);
      QtSceneActions.register(8, b.add);
      QtSceneActions.setContext(7, 3);
      QtSceneActions.setContext(8, 5);

      // A 生产、排队期间 B 已经登记：A 的回执必须按 A 的 ctx(3) 校验。
      await QtSceneActions.handleNativeCall(const MethodCall(
        'action',
        <String, Object?>{'viewId': 7, 'ctx': 3, 'action': 'archive-scroll:commit:2.0'},
      ));
      expect(a, <String>['archive-scroll:commit:2.0']);
      expect(b, isEmpty);

      // 同一个动作若被贴上 B 的新代次，就是"用当前全局 origin 重贴标签"的旧缺陷，
      // 必须被丢弃而不是下发给 A。
      await QtSceneActions.handleNativeCall(const MethodCall(
        'action',
        <String, Object?>{'viewId': 7, 'ctx': 5, 'action': 'archive-scroll:commit:2.0'},
      ));
      expect(a, hasLength(1));
      expect(b, isEmpty);
    });

    test('已登记但还没有代次（unbound）→ 丢弃；代次为 0 → 丢弃', () async {
      final List<String> got = <String>[];
      QtSceneActions.register(9, got.add);
      await QtSceneActions.handleNativeCall(const MethodCall(
        'action',
        <String, Object?>{'viewId': 9, 'ctx': 1, 'action': 'archive-select:0:0'},
      ));
      expect(got, isEmpty, reason: 'unbound：不知道它在哪个集合上下文里，不能下发');

      QtSceneActions.setContext(9, 4);
      await QtSceneActions.handleNativeCall(const MethodCall(
        'action',
        <String, Object?>{'viewId': 9, 'ctx': 0, 'action': 'archive-select:0:0'},
      ));
      expect(got, isEmpty, reason: 'ctx 0 表示未登记，同样不可信');

      await QtSceneActions.handleNativeCall(const MethodCall(
        'action',
        <String, Object?>{'viewId': 9, 'ctx': 4, 'action': 'archive-select:0:0'},
      ));
      expect(got, <String>['archive-select:0:0']);
    });

    test('解绑（unregister）之后迟到的动作不再交给页面', () async {
      final List<String> got = <String>[];
      QtSceneActions.register(10, got.add);
      QtSceneActions.setContext(10, 2);
      QtSceneActions.unregister(10);
      await QtSceneActions.handleNativeCall(const MethodCall(
        'action',
        <String, Object?>{'viewId': 10, 'ctx': 2, 'action': 'archive-select:1:1'},
      ));
      expect(got, isEmpty);
    });
  });

  group('QtSceneStateSender：ctx 是 payload 的一部分，去重不吞新代次', () {
    test('同一份 json 换 ctx 必须重发（否则 Qt 侧永远学不到新代次）', () async {
      final List<MethodCall> calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel(qtSceneChannelName),
              (MethodCall call) async {
        calls.add(call);
        return true;
      });
      final QtSceneStateSender sender = QtSceneStateSender();
      expect(await sender.push(7, '{"v":4}', contextGeneration: 3), isTrue);
      expect(await sender.push(7, '{"v":4}', contextGeneration: 3), isFalse);
      expect(await sender.push(7, '{"v":4}', contextGeneration: 4), isTrue);
      expect(calls, hasLength(2));
      expect(
        (calls.last.arguments as Map<Object?, Object?>)['ctx'],
        4,
      );
    });

    test('去重按视图隔离：不同视图的同一份 json 各自都要发', () async {
      final List<MethodCall> calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel(qtSceneChannelName),
              (MethodCall call) async {
        calls.add(call);
        return true;
      });
      final QtSceneStateSender sender = QtSceneStateSender();
      expect(await sender.push(7, '{"v":4}', contextGeneration: 1), isTrue);
      expect(await sender.push(8, '{"v":4}', contextGeneration: 2), isTrue);
      expect(calls, hasLength(2));
    });
  });

  group('快照：origin 与位置各归各位', () {
    test('view/ctx 进 payload，位置变化不影响集合身份（合法惯性）', () {
      final List<BasicListItem> lane = <BasicListItem>[_item('a'), _item('b')];
      final BasicViewState parked = _state(
        songs: <SirenSong>[_song('a')],
        laneItems: <List<BasicListItem>>[lane],
      );
      final BasicViewState dragging = _state(
        songs: <SirenSong>[_song('a')],
        laneItems: <List<BasicListItem>>[lane],
        listPosition: 12.5,
        playing: true,
      );

      final Map<String, Object?> snapshot = _decode(qtSceneStateSnapshot(
        dragging,
        viewId: 7,
        contextGeneration: 3,
      ));
      expect(snapshot['view'], 7);
      expect(snapshot['ctx'], 3);
      expect(snapshot['pos'], 12.5, reason: '位置要进快照，Qt 才能续上惯性');
      expect(
        qtSceneIdentitySignature(parked),
        qtSceneIdentitySignature(dragging),
        reason: '位置/播放变化不是集合身份变化，不能换代次',
      );
    });
  });
}
