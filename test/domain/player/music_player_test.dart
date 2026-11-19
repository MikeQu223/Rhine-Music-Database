/// 播放传输状态机测试（未执行：本任务禁止 flutter test / dart test）。
///
/// 证据源：Qt/src/MusicPlayer.cpp（各用例注释给出 Qt 行号）、Qt/src/Host.h:44-49、
/// Qt/src/AudioPlayer.cpp:430-443、lib/domain/player/music_player.dart。
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:rhine_music_database/domain/player/music_player.dart';
import 'package:rhine_music_database/domain/player/playback_queue.dart';

/// 曲目对象与 Qt JSON 同形（MusicPlayer.cpp:410-412 的 track 结构）。
Map<String, Object?> song(
  String id, {
  String provider = 'netease',
  String? title,
  Map<String, Object?>? extra,
}) {
  return <String, Object?>{
    'kind': 'song',
    'id': id,
    'provider': provider,
    'title': title ?? ('T$id'),
    ...?extra,
  };
}

/// 媒体宿主端口替身：记录下发的控制、元数据与 state 读取次数（Host.h:44-49）。
class FakeMedia implements MediaHostPort {
  final List<String> controls = <String>[];
  final List<double> values = <double>[];
  final List<String> metadata = <String>[];
  Map<String, Object?> snapshot = <String, Object?>{};
  int stateReads = 0;

  @override
  void mediaControl(String action, [double value = 0]) {
    controls.add(action);
    values.add(value);
  }

  @override
  Map<String, Object?> mediaState() {
    stateReads++;
    return Map<String, Object?>.of(snapshot);
  }

  @override
  void mediaMetadata(String title, String artist, String album, String cover) {
    metadata
      ..clear()
      ..addAll(<String>[title, artist, album, cover]);
  }
}

/// 偏好端口替身：play-history 的读写（MusicPlayer.cpp:188、:421-422、:667）。
class FakePreferences implements PreferencePort {
  final Map<String, String> values = <String, String>{};
  final List<String> writes = <String>[];

  void seed(String key, String value) {
    values[key] = value;
  }

  @override
  String read(String key) => values[key] ?? '';

  @override
  void write(String key, String value) {
    values[key] = value;
    writes.add(key);
  }
}

/// 音源准备端口替身：记录 prepare 的曲目、代数与 reload（MusicPlayer.cpp:291、:469、:641）。
class FakeEngine implements PlaybackEnginePort {
  final List<Map<String, Object?>> prepared = <Map<String, Object?>>[];
  final List<int> generations = <int>[];
  final List<bool> reloads = <bool>[];

  @override
  void prepare(Map<String, Object?> track, int generation, {bool reload = false}) {
    prepared.add(Map<String, Object?>.of(track));
    generations.add(generation);
    reloads.add(reload);
  }
}

/// 组装播放器与三个端口；provider 对齐 Qt m_api->provider（:264）。
class Harness {
  Harness({String history = '', String provider = 'netease'}) {
    if (history.isNotEmpty) {
      preferences.seed('play-history', history);
    }
    player = MusicPlayer(
      media: media,
      preferences: preferences,
      engine: engine,
      provider: () => provider,
    );
    player.addListener(() {
      changes++;
    });
  }

  final FakeMedia media = FakeMedia();
  final FakePreferences preferences = FakePreferences();
  final FakeEngine engine = FakeEngine();
  late final MusicPlayer player;
  int changes = 0;
}

void main() {
  group('构造（Qt MusicPlayer.cpp:159-223）', () {
    test('state 初值逐键对齐 MusicPlayer.cpp:161，mode 缺省 all（MusicPlayer.h:48）', () {
      final h = Harness();
      expect(h.player.state, <String, Object?>{
        'playing': false,
        'position': 0.0,
        'duration': 0.0,
        'volume': 0.7,
        'seekable': false,
      });
      expect(h.player.mode, 'all');
      expect(h.player.current, isEmpty);
      expect(h.player.history, isEmpty);
      expect(h.player.loading, isFalse);
      expect(h.player.failed, isFalse);
      expect(h.player.queue, isA<PlaybackQueue>());
      expect(h.player.queue.isEmpty, isTrue);
      expect(h.changes, 0);
    });

    test('play-history 回填按 kind 与 id 形状过滤（:188-198）', () {
      final h = Harness(
        history: '['
            '{"kind":"song","id":"a-1","provider":"netease","title":"A"},'
            '{"kind":"video","id":"v-1"},'
            '{"kind":"song","id":"bad id"},'
            '{"kind":"song","id":"b_2","provider":"qq"}'
            ']',
      );
      expect(h.player.history.length, 2);
      expect(h.player.history[0]['id'], 'a-1');
      expect(h.player.history[1]['id'], 'b_2');
    });

    test('回填最多 200 条，先追加后判断（:194-196）', () {
      final entries = <String>[];
      for (var i = 0; i < 205; i++) {
        entries.add('{"kind":"song","id":"s$i"}');
      }
      final h = Harness(history: '[${entries.join(',')}]');
      expect(h.player.history.length, 200);
      expect(h.player.history.first['id'], 's0');
      expect(h.player.history.last['id'], 's199');
    });

    test('偏好不是 JSON 数组时视为空（QJsonDocument::fromJson(...).array()）', () {
      expect(Harness(history: 'not json').player.history, isEmpty);
      expect(Harness(history: '{"a":1}').player.history, isEmpty);
    });
  });

  group('enqueue（Qt MusicPlayer.cpp:229-246）', () {
    test('非歌曲被拒绝（:242-244）', () {
      final h = Harness();
      expect(h.player.enqueue(<String, Object?>{'kind': 'video', 'id': 'v'}), isFalse);
      expect(h.player.queue.isEmpty, isTrue);
    });

    test('默认追加到队尾且不切歌（:229、:245）', () {
      final h = Harness();
      h.player.queue.replace(<Map<String, Object?>>[song('a'), song('b')]);
      h.player.queue.select(0);
      expect(h.player.enqueue(song('c')), isTrue);
      expect(h.player.queue.items.map((track) => track['id']).toList(), <Object?>['a', 'b', 'c']);
      expect(h.player.queue.index, 0);
      expect(h.player.current, isEmpty);
    });

    test('next 插到当前项之后（:229）', () {
      final h = Harness();
      h.player.queue.replace(<Map<String, Object?>>[song('a'), song('b'), song('c')]);
      h.player.queue.select(1);
      expect(h.player.enqueue(song('d'), next: true), isTrue);
      expect(h.player.queue.items.map((track) => track['id']).toList(), <Object?>['a', 'b', 'd', 'c']);
      expect(h.player.queue.index, 1);
    });

    test('去除非当前项中的同曲再插入，索引随删除前移（:229）', () {
      final h = Harness();
      h.player.queue.replace(<Map<String, Object?>>[song('a'), song('b'), song('c')]);
      h.player.queue.select(1);
      expect(h.player.enqueue(song('a'), next: true), isTrue);
      expect(h.player.queue.items.map((track) => track['id']).toList(), <Object?>['b', 'a', 'c']);
      expect(h.player.queue.index, 0);
    });
  });

  group('play（Qt MusicPlayer.cpp:248-292）', () {
    test('非歌曲直接忽略，不触碰媒体与音源（:264-267）', () {
      final h = Harness();
      h.player.play(<String, Object?>{'kind': 'video', 'id': 'v'});
      expect(h.engine.prepared, isEmpty);
      expect(h.player.queue.isEmpty, isTrue);
      expect(h.player.current, isEmpty);
      expect(h.media.controls, isEmpty);
    });

    test('本地来源不一致时忽略（:264-267）', () {
      final local = Harness(provider: 'local');
      local.player.play(song('a'));
      expect(local.engine.prepared, isEmpty);
      final remote = Harness(provider: 'netease');
      remote.player.play(song('a', provider: 'local'));
      expect(remote.engine.prepared, isEmpty);
    });

    test('source 替换队列并按身份选曲（:268-271、:281-290）', () {
      final h = Harness();
      h.player.play(song('c'), source: <Map<String, Object?>>[song('a'), song('b'), song('c')]);
      expect(h.player.queue.items.map((track) => track['id']).toList(), <Object?>['a', 'b', 'c']);
      expect(h.player.queue.index, 2);
      expect(h.player.current['id'], 'c');
      expect(h.player.loading, isTrue);
      expect(h.player.failed, isFalse);
      expect(h.player.trial, isFalse);
      expect(h.player.status, '正在准备：Tc');
      expect(h.engine.generations, <int>[1]);
      expect(h.engine.prepared.single['id'], 'c');
      expect(h.media.controls, <String>['stop']);
      expect(h.changes, greaterThan(0));
    });

    test('queueIndex 装配即生效，0 也选中（std::optional，:272-274）', () {
      final h = Harness();
      h.player.play(song('b'), source: <Map<String, Object?>>[song('a'), song('b')], queueIndex: 0);
      expect(h.player.current['id'], 'b');
      expect(h.player.queue.index, 0);
      expect(h.player.queue.at(0)['id'], 'a');
    });

    test('resume 装配位置与暂停意图（:276-278）', () {
      final h = Harness();
      h.player.play(song('a'), source: <Map<String, Object?>>[song('a')], resume: <String, Object?>{'position': 12.5, 'requested': false});
      final session = h.player.sessionState();
      expect(session['position'], 12.5);
      expect(session['requested'], isFalse);
    });

    test('resume 缺 requested 时按 false 处理（:277）', () {
      final h = Harness();
      h.player.play(song('a'), source: <Map<String, Object?>>[song('a')], resume: <String, Object?>{'position': 0});
      expect(h.player.sessionState()['requested'], isFalse);
    });

    test('preview 只在 qq 来源生效（:280）', () {
      final qq = Harness(provider: 'qq');
      qq.player.play(song('a', provider: 'qq'), preview: true);
      expect(qq.player.previewRequested, isTrue);
      final netease = Harness();
      netease.player.play(song('a'), preview: true);
      expect(netease.player.previewRequested, isFalse);
    });

    test('每次 play 推进代数并下发 stop（:275、:281）', () {
      final h = Harness();
      h.player.play(song('a'), source: <Map<String, Object?>>[song('a')]);
      h.player.play(song('b'), source: <Map<String, Object?>>[song('a'), song('b')]);
      expect(h.engine.generations, <int>[1, 2]);
      expect(h.media.controls, <String>['stop', 'stop']);
    });
  });

  group('tick（Qt MusicPlayer.cpp:471-518）', () {
    test('非 force 时 0.1 秒节流（:475-477）', () {
      final h = Harness();
      h.player.tick(0);
      expect(h.media.stateReads, 1);
      h.player.tick(0.05);
      expect(h.media.stateReads, 1);
      h.player.tick(0.05, force: true);
      expect(h.media.stateReads, 2);
    });

    test('合并 mediaState，仅在状态变化时发 changed（:480-483、:515-516）', () {
      final h = Harness();
      h.media.snapshot = <String, Object?>{'position': 3.0};
      h.player.tick(0);
      expect(h.player.state['position'], 3.0);
      expect(h.changes, 1);
      h.player.tick(1);
      expect(h.changes, 1);
      h.media.snapshot = <String, Object?>{'position': 4.0};
      h.player.tick(2);
      expect(h.player.state['position'], 4.0);
      expect(h.changes, 2);
    });

    test('恢复定位在可定位且加载完成后下发并消费（:484-491）', () {
      final h = Harness();
      h.player.play(song('a'), source: <Map<String, Object?>>[song('a')], resume: <String, Object?>{'position': 5.0, 'requested': true});
      h.player.fail('boom');
      expect(h.player.loading, isFalse);
      h.media.snapshot = <String, Object?>{'seekable': true, 'duration': 10.0};
      h.player.tick(0);
      expect(h.media.controls.last, 'seek');
      expect(h.media.values.last, 5.0);
      expect(h.player.sessionState()['position'], 0.0);
    });

    test('待恢复暂停意图在 seek 后补发 pause（:488-490）', () {
      final h = Harness();
      h.player.play(song('a'), source: <Map<String, Object?>>[song('a')], resume: <String, Object?>{'position': 2.0, 'requested': false});
      h.player.fail('boom');
      h.media.snapshot = <String, Object?>{'seekable': true, 'duration': 10.0};
      h.player.tick(0);
      expect(h.media.controls.sublist(h.media.controls.length - 2), <String>['seek', 'pause']);
    });

    test('结束事件只推进一次（:493-504）', () {
      final h = Harness();
      h.player.play(song('a'), source: <Map<String, Object?>>[song('a'), song('b')]);
      h.player.playbackStarted();
      h.media.snapshot = <String, Object?>{'ended': 1};
      h.player.tick(0);
      expect(h.player.current['id'], 'b');
      expect(h.player.queue.index, 1);
      expect(h.engine.generations, <int>[1, 2]);
      h.player.tick(1);
      expect(h.player.current['id'], 'b');
      expect(h.engine.generations, <int>[1, 2]);
    });

    test('onEnd 存在时结束交给钩子，不自动下一首（:498-499）', () {
      final h = Harness();
      var ended = 0;
      h.player.onEnd = () {
        ended++;
      };
      h.player.play(song('a'), source: <Map<String, Object?>>[song('a'), song('b')]);
      h.player.playbackStarted();
      h.media.snapshot = <String, Object?>{'ended': 3};
      h.player.tick(0);
      expect(ended, 1);
      expect(h.player.queue.index, 0);
      expect(h.engine.generations, <int>[1]);
    });

    test('可恢复错误重建音源并保留位置与意图（:505-513、:457-469）', () {
      final h = Harness();
      h.player.play(song('a'), source: <Map<String, Object?>>[song('a')]);
      h.player.playbackStarted();
      h.media.snapshot = <String, Object?>{'error': 'E', 'recoverable': true, 'position': 3.0, 'requested': true};
      h.player.tick(0);
      expect(h.player.status, '正在恢复播放（1/2）…');
      expect(h.player.loading, isTrue);
      expect(h.player.failed, isFalse);
      expect(h.engine.generations, <int>[1, 2]);
      expect(h.engine.reloads, <bool>[false, true]);
      final session = h.player.sessionState();
      expect(session['position'], 3.0);
      expect(session['requested'], isTrue);
    });

    test('重试上限 2 后转为失败（:508-514）', () {
      final h = Harness();
      h.player.play(song('a'), source: <Map<String, Object?>>[song('a')]);
      h.player.playbackStarted();
      h.media.snapshot = <String, Object?>{'error': 'E', 'recoverable': true};
      h.player.tick(0);
      h.player.playbackStarted();
      h.player.tick(1);
      h.player.playbackStarted();
      h.player.tick(2);
      expect(h.player.failed, isTrue);
      expect(h.player.status, 'E');
      expect(h.engine.reloads, <bool>[false, true, true]);
    });

    test('本地来源或不可恢复错误直接失败（:509-514）', () {
      final local = Harness(provider: 'local');
      local.player.play(song('a', provider: 'local'), source: <Map<String, Object?>>[song('a', provider: 'local')]);
      local.player.playbackStarted();
      local.media.snapshot = <String, Object?>{'error': 'E1', 'recoverable': true};
      local.player.tick(0);
      expect(local.player.failed, isTrue);
      expect(local.player.status, 'E1');
      expect(local.engine.reloads, <bool>[false]);

      final plain = Harness();
      plain.player.play(song('a'), source: <Map<String, Object?>>[song('a')]);
      plain.player.playbackStarted();
      plain.media.snapshot = <String, Object?>{'error': 'E2'};
      plain.player.tick(0);
      expect(plain.player.failed, isTrue);
      expect(plain.player.status, 'E2');
    });

    test('相同错误文本不重复失败（:507）', () {
      final h = Harness();
      h.player.play(song('a'), source: <Map<String, Object?>>[song('a')]);
      h.player.playbackStarted();
      h.media.snapshot = <String, Object?>{'error': 'E3'};
      h.player.tick(0);
      final changes = h.changes;
      h.player.tick(1);
      expect(h.changes, changes);
      expect(h.player.failed, isTrue);
    });
  });

  group('toggle / setPaused / seek（Qt MusicPlayer.cpp:520-559）', () {
    test('无当前曲目时 toggle 不下发控制（:533-535）', () {
      final h = Harness();
      h.player.toggle();
      expect(h.media.controls, isEmpty);
    });

    test('toggle 用当前 playing 取反（:533-535、:538-546）', () {
      final h = Harness();
      h.player.play(song('a'), source: <Map<String, Object?>>[song('a')]);
      h.player.playbackStarted();
      h.media.snapshot = <String, Object?>{'playing': true};
      h.player.tick(0);
      h.player.toggle();
      expect(h.media.controls.last, 'pause');
      h.player.toggle();
      expect(h.media.controls.last, 'pause');
      h.media.snapshot = <String, Object?>{'playing': false};
      h.player.tick(1);
      h.player.toggle();
      expect(h.media.controls.last, 'resume');
    });

    test('setPaused 不发 changed（:538-546）', () {
      final h = Harness();
      h.player.play(song('a'), source: <Map<String, Object?>>[song('a')]);
      h.player.playbackStarted();
      final before = h.changes;
      h.player.setPaused(true);
      expect(h.changes, before);
      expect(h.media.controls.last, 'pause');
    });

    test('待恢复定位装配时 toggle 只翻转意图（:529-531）', () {
      final h = Harness();
      h.player.play(song('a'), source: <Map<String, Object?>>[song('a')], resume: <String, Object?>{'position': 4.0, 'requested': true});
      h.player.toggle();
      expect(h.player.sessionState()['requested'], isFalse);
      expect(h.media.controls.last, 'pause');
      expect(h.media.controls.contains('seek'), isFalse);
    });

    test('seek 在待恢复时折算为位置且不下发（:552-554）', () {
      final h = Harness();
      h.player.play(song('a'), source: <Map<String, Object?>>[song('a')], resume: <String, Object?>{'position': 0.0});
      h.media.snapshot = <String, Object?>{'duration': 100.0};
      h.player.tick(0);
      h.player.seek(0.5);
      expect(h.player.sessionState()['position'], 50.0);
      expect(h.media.controls.contains('seek'), isFalse);
    });

    test('seek 在可定位时下发比例秒数并夹取（:556-557）', () {
      final h = Harness();
      h.player.play(song('a'), source: <Map<String, Object?>>[song('a')]);
      h.player.playbackStarted();
      h.media.snapshot = <String, Object?>{'seekable': true, 'duration': 40.0};
      h.player.tick(0);
      h.player.seek(0.25);
      expect(h.media.controls.last, 'seek');
      expect(h.media.values.last, 10.0);
      h.player.seek(2.0);
      expect(h.media.values.last, 40.0);
    });

    test('不可定位且无待恢复位置时不 seek（:556-557）', () {
      final h = Harness();
      h.player.play(song('a'), source: <Map<String, Object?>>[song('a')]);
      h.player.playbackStarted();
      h.player.seek(0.5);
      expect(h.media.controls.contains('seek'), isFalse);
    });
  });

  group('next / remove / clearUpcoming（Qt MusicPlayer.cpp:573-601）', () {
    test('空队列直接返回（:577-579）', () {
      final h = Harness();
      h.player.next();
      expect(h.media.controls, isEmpty);
    });

    test('顺序模式推进到下一首并播放（:577-586）', () {
      final h = Harness();
      h.player.play(song('a'), source: <Map<String, Object?>>[song('a'), song('b'), song('c')]);
      h.player.playbackStarted();
      h.player.next();
      expect(h.player.current['id'], 'b');
      expect(h.player.queue.index, 1);
      expect(h.engine.generations, <int>[1, 2]);
    });

    test('off 模式到末尾报告队列已播放完（:582-583）', () {
      final h = Harness();
      h.player.setMode('off');
      h.player.play(song('c'), source: <Map<String, Object?>>[song('a'), song('b'), song('c')]);
      h.player.playbackStarted();
      h.player.next();
      expect(h.player.status, '队列已播放完');
      expect(h.player.queue.index, 2);
      expect(h.engine.generations, <int>[1]);
    });

    test('单曲循环停在当前项（PlaybackQueue.cpp:261-262）', () {
      final h = Harness();
      h.player.setMode('one');
      h.player.play(song('b'), source: <Map<String, Object?>>[song('a'), song('b'), song('c')]);
      h.player.next();
      expect(h.player.current['id'], 'b');
      expect(h.player.queue.index, 1);
      expect(h.engine.generations, <int>[1, 2]);
    });

    test('remove 由队列拒绝当前项（:589-594；PlaybackQueue.cpp:173-183）', () {
      final h = Harness();
      h.player.play(song('b'), source: <Map<String, Object?>>[song('a'), song('b'), song('c')]);
      h.player.remove(1);
      expect(h.player.queue.size, 3);
      h.player.remove(2);
      expect(h.player.queue.size, 2);
      expect(h.player.queue.index, 1);
    });

    test('clearUpcoming 只保留当前项（:596-601；PlaybackQueue.cpp:193-204）', () {
      final h = Harness();
      h.player.play(song('b'), source: <Map<String, Object?>>[song('a'), song('b'), song('c')]);
      h.player.clearUpcoming();
      expect(h.player.queue.items.map((track) => track['id']).toList(), <Object?>['b']);
      expect(h.player.queue.index, 0);
    });
  });

  group('stop / mode / clearHistory（Qt MusicPlayer.cpp:603-669）', () {
    test('stop 只重置播放三键，保留 volume 与 seekable（:608-624、:621-623）', () {
      final h = Harness();
      h.player.play(song('a'), source: <Map<String, Object?>>[song('a'), song('b')]);
      h.player.playbackStarted();
      h.media.snapshot = <String, Object?>{'volume': 0.4, 'seekable': true, 'position': 5.0};
      h.player.tick(0);
      h.player.stop();
      expect(h.player.current, isEmpty);
      expect(h.player.queue.isEmpty, isTrue);
      expect(h.player.loading, isFalse);
      expect(h.player.failed, isFalse);
      expect(h.player.status, '');
      expect(h.player.state, <String, Object?>{
        'playing': false,
        'position': 0.0,
        'duration': 0.0,
        'volume': 0.4,
        'seekable': true,
      });
      expect(h.media.controls.last, 'stop');
      expect(h.media.metadata, <String>['', '', '', '']);
    });

    test('stop 后迟到的音源回调被 generation 拦截（:442、:608）', () {
      final h = Harness();
      h.player.play(song('a'), source: <Map<String, Object?>>[song('a')]);
      final generation = h.engine.generations.single;
      h.player.stop();
      h.player.playbackStarted(generation: generation);
      expect(h.player.history, isEmpty);
      expect(h.player.loading, isFalse);
    });

    test('setMode 白名单外忽略且不发 changed（:643-650）', () {
      final h = Harness();
      final before = h.changes;
      h.player.setMode('repeat');
      expect(h.player.mode, 'all');
      expect(h.changes, before);
    });

    test('setMode 白名单内更新并发 changed（:647-650）', () {
      final h = Harness();
      final before = h.changes;
      h.player.setMode('shuffle');
      expect(h.player.mode, 'shuffle');
      expect(h.changes, before + 1);
    });

    test('clearHistory 清空并写回空数组（:662-669）', () {
      final h = Harness();
      h.player.play(song('a'), source: <Map<String, Object?>>[song('a')]);
      h.player.playbackStarted();
      expect(h.player.history, isNotEmpty);
      h.player.clearHistory();
      expect(h.player.history, isEmpty);
      expect(h.preferences.read('play-history'), '[]');
      expect(h.preferences.writes, contains('play-history'));
    });
  });

  group('sessionState（Qt MusicPlayer.cpp:749-758）', () {
    test('键集固定，index/mode/preview 直取（:756-757）', () {
      final h = Harness();
      h.player.play(song('a'), source: <Map<String, Object?>>[song('a'), song('b')], queueIndex: 0);
      final session = h.player.sessionState();
      expect(session.keys.toSet(), <String>{'current', 'queue', 'index', 'mode', 'position', 'requested', 'preview'});
      expect(session['index'], 0);
      expect(session['mode'], 'all');
      expect(session['preview'], isFalse);
      expect((session['queue'] as List<Object?>).length, 2);
      expect((session['current'] as Map<String, Object?>)['id'], 'a');
    });

    test('位置优先取 mediaState，缺失回落 state.position（:751-752）', () {
      final h = Harness();
      h.media.snapshot = <String, Object?>{'position': 7.0, 'requested': true};
      h.player.tick(0);
      expect(h.player.sessionState()['position'], 7.0);
      expect(h.player.sessionState()['requested'], isTrue);
      h.media.snapshot = <String, Object?>{};
      h.player.tick(1);
      expect(h.player.sessionState()['position'], 7.0);
      expect(h.player.sessionState()['requested'], isFalse);
    });

    test('待恢复位置与暂停意图优先（:751-755）', () {
      final h = Harness();
      h.player.play(song('a'), source: <Map<String, Object?>>[song('a')], resume: <String, Object?>{'position': 9.0, 'requested': false});
      final session = h.player.sessionState();
      expect(session['position'], 9.0);
      expect(session['requested'], isFalse);
    });
  });

  group('restoreSessionState（Qt MusicPlayer.cpp:760-780）', () {
    test('position 越界整体放弃（:761-764）', () {
      final h = Harness();
      h.player.setMode('one');
      h.player.restoreSessionState(<String, Object?>{'position': 1e13, 'mode': 'all'});
      expect(h.player.mode, 'one');
      final negative = Harness();
      negative.player.restoreSessionState(<String, Object?>{'position': -1.0, 'mode': 'all', 'queue': <Object?>[song('a')]});
      expect(negative.player.queue.isEmpty, isTrue);
      final missing = Harness();
      missing.player.restoreSessionState(<String, Object?>{'mode': 'all', 'queue': <Object?>[song('a')]});
      expect(missing.player.queue.isEmpty, isTrue);
    });

    test('mode 先于 current 判定赋值（:765-766）', () {
      final h = Harness();
      h.player.setMode('off');
      h.player.restoreSessionState(<String, Object?>{'position': 0, 'mode': 'shuffle', 'current': <String, Object?>{'kind': 'video', 'id': 'v'}});
      expect(h.player.mode, 'shuffle');
      expect(h.player.queue.isEmpty, isTrue);
      expect(h.engine.prepared, isEmpty);
    });

    test('mode 白名单外回落 all（:766）', () {
      final h = Harness();
      h.player.setMode('shuffle');
      h.player.restoreSessionState(<String, Object?>{'position': 0, 'mode': 'repeat'});
      expect(h.player.mode, 'all');
    });

    test('空 current 只恢复队列并通知（:769-773）', () {
      final h = Harness();
      h.player.restoreSessionState(<String, Object?>{'position': 0, 'queue': <Object?>[song('a'), song('b')], 'index': 1});
      expect(h.player.queue.items.map((track) => track['id']).toList(), <Object?>['a', 'b']);
      expect(h.player.queue.index, 1);
      expect(h.player.current, isEmpty);
      expect(h.changes, greaterThan(0));
      expect(h.engine.prepared, isEmpty);
    });

    test('kind/provider 守卫先于队列恢复（:774-776）', () {
      final video = Harness();
      video.player.restoreSessionState(<String, Object?>{'position': 0, 'current': <String, Object?>{'kind': 'video', 'id': 'v'}, 'queue': <Object?>[song('a')]});
      expect(video.player.queue.isEmpty, isTrue);
      final foreign = Harness();
      foreign.player.restoreSessionState(<String, Object?>{'position': 0, 'current': song('a', provider: 'qq'), 'queue': <Object?>[song('a', provider: 'qq')]});
      expect(foreign.player.queue.isEmpty, isTrue);
      expect(foreign.engine.prepared, isEmpty);
    });

    test('完整会话先恢复队列再选曲（:777-779）', () {
      final h = Harness();
      h.player.restoreSessionState(<String, Object?>{
        'position': 12.5,
        'mode': 'all',
        'current': song('b'),
        'queue': <Object?>[song('a'), song('b'), song('c')],
        'index': 1,
        'preview': true,
        'requested': true,
      });
      expect(h.player.queue.items.map((track) => track['id']).toList(), <Object?>['a', 'b', 'c']);
      expect(h.player.queue.index, 1);
      expect(h.player.current['id'], 'b');
      expect(h.player.loading, isTrue);
      expect(h.player.status, '正在准备：Tb');
      expect(h.player.previewRequested, isFalse);
      expect(h.engine.generations, <int>[1]);
      final session = h.player.sessionState();
      expect(session['position'], 12.5);
      expect(session['requested'], isTrue);
    });

    test('index 按 int32 语义取值（QJsonValue::toInt，qjsonvalue.cpp:686-705）', () {
      final h = Harness();
      h.player.restoreSessionState(<String, Object?>{'position': 0, 'queue': <Object?>[song('a'), song('b')], 'index': 2147483648});
      expect(h.player.queue.size, 2);
      expect(h.player.queue.index, -1);
    });
  });

  group('queue.changed 转发与音源回调（Qt MusicPlayer.cpp:162、:408-454）', () {
    test('队列事件直接转发到播放器 changed（:162）', () {
      final h = Harness();
      h.player.queue.enqueue(song('a'));
      expect(h.changes, 1);
    });

    test('playbackStarted 推历史并去重当前项（:410-422）', () {
      final h = Harness(
        history: '[{"kind":"song","id":"x","provider":"netease"},'
            '{"kind":"song","id":"a","provider":"netease"}]',
      );
      h.player.play(song('a'), source: <Map<String, Object?>>[song('a')]);
      h.player.playbackStarted();
      expect(h.player.history.length, 2);
      expect(h.player.history.first['id'], 'a');
      expect(h.player.history.first['wiki'], '');
      expect(h.player.history.first['description'], '');
      expect(h.player.history[1]['id'], 'x');
      final saved = jsonDecode(h.preferences.read('play-history')) as List<Object?>;
      expect(saved.length, 2);
    });

    test('playbackStarted 截断到 200 条（:414-419）', () {
      final entries = <String>[];
      for (var i = 0; i < 200; i++) {
        entries.add('{"kind":"song","id":"h$i"}');
      }
      final h = Harness(history: '[${entries.join(',')}]');
      h.player.play(song('a'), source: <Map<String, Object?>>[song('a')]);
      h.player.playbackStarted();
      expect(h.player.history.length, 200);
      expect(h.player.history.first['id'], 'a');
    });

    test('playbackStarted 记录 ended 序列，避免重复推进（:409）', () {
      final h = Harness();
      h.media.snapshot = <String, Object?>{'ended': 7};
      h.player.play(song('a'), source: <Map<String, Object?>>[song('a')]);
      h.player.playbackStarted();
      h.player.tick(1);
      expect(h.player.current['id'], 'a');
      expect(h.engine.generations, <int>[1]);
    });

    test('fail 在恢复会话期间保留待恢复位置（:445-448）', () {
      final h = Harness();
      h.player.play(song('a'), source: <Map<String, Object?>>[song('a')], resume: <String, Object?>{'position': 4.0, 'requested': true});
      h.player.fail('E');
      expect(h.player.failed, isTrue);
      expect(h.player.status, 'E');
      expect(h.player.loading, isFalse);
      expect(h.player.sessionState()['position'], 4.0);
    });

    test('fail 拦截过期 generation（Qt :442；Dart :617-620）', () {
      final h = Harness();
      h.player.play(song('a'), source: <Map<String, Object?>>[song('a')]);
      final stale = h.engine.generations.single;
      h.player.play(song('b'), source: <Map<String, Object?>>[song('a'), song('b')]);
      h.player.fail('late', generation: stale);
      expect(h.player.failed, isFalse);
      expect(h.player.loading, isTrue);
    });
  });
}
