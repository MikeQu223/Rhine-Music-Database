/// MusicPlayer 公开播放模式入口与队列动作测试。
///
/// 端口替身与 test/domain/player/music_player_test.dart 的同名类逐字段一致（FakeMedia /
/// FakePreferences / FakeEngine + Harness），复用同款约定而不另写一套。
/// 证据源：lib/domain/player/music_player.dart 的 setMode / clearUpcoming / removeFromQueue /
/// queueLength / queueIndex / hasQueue；Qt/src/MusicPlayer.cpp:643-651（mode 白名单）、
/// :589-601（remove / clearUpcoming）、Qt/src/PlaybackQueue.cpp:173-204。
library;

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

/// 媒体宿主端口替身（Host.h:44-49）。
class FakeMedia implements MediaHostPort {
  final List<String> controls = <String>[];
  final List<double> values = <double>[];
  final List<String> metadata = <String>[];
  Map<String, Object?> snapshot = <String, Object?>{};

  @override
  void mediaControl(String action, [double value = 0]) {
    controls.add(action);
    values.add(value);
  }

  @override
  Map<String, Object?> mediaState() => Map<String, Object?>.of(snapshot);

  @override
  void mediaMetadata(String title, String artist, String album, String cover) {
    metadata
      ..clear()
      ..addAll(<String>[title, artist, album, cover]);
  }
}

/// 偏好端口替身（MusicPlayer.cpp:188、:421-422、:667）。
class FakePreferences implements PreferencePort {
  final Map<String, String> values = <String, String>{};
  final List<String> writes = <String>[];

  @override
  String read(String key) => values[key] ?? '';

  @override
  void write(String key, String value) {
    values[key] = value;
    writes.add(key);
  }
}

/// 音源准备端口替身（MusicPlayer.cpp:291、:469、:641）。
class FakeEngine implements PlaybackEnginePort {
  final List<Map<String, Object?>> prepared = <Map<String, Object?>>[];
  final List<int> generations = <int>[];

  @override
  void prepare(Map<String, Object?> track, int generation, {bool reload = false}) {
    prepared.add(Map<String, Object?>.of(track));
    generations.add(generation);
  }
}

/// 组装播放器与三个端口；provider 对齐 Qt m_api->provider（:264）。
class Harness {
  Harness({String provider = 'netease'}) {
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
  group('setMode 公开入口（Qt MusicPlayer.cpp:643-651）', () {
    test('四个合法取值逐个接受并返回 true', () {
      final h = Harness();
      for (final value in <String>['off', 'all', 'one', 'shuffle']) {
        expect(h.player.setMode(value), isTrue, reason: value);
        expect(h.player.mode, value, reason: value);
        expect(h.player.sessionState()['mode'], value, reason: value);
      }
    });

    test('非法取值返回 false 且 mode 与 changed 均不动', () {
      final h = Harness();
      h.player.setMode('shuffle');
      final before = h.changes;
      expect(h.player.setMode('repeat'), isFalse);
      expect(h.player.setMode(''), isFalse);
      expect(h.player.setMode('ALL'), isFalse);
      expect(h.player.mode, 'shuffle');
      expect(h.changes, before);
    });

    test('重复设置同一合法值仍返回 true 并按一次 changed 计', () {
      final h = Harness();
      final before = h.changes;
      expect(h.player.setMode('one'), isTrue);
      expect(h.player.setMode('one'), isTrue);
      expect(h.changes, before + 2);
      expect(h.player.mode, 'one');
    });
  });

  group('队列动作（Qt MusicPlayer.cpp:589-601；PlaybackQueue.cpp:173-204）', () {
    test('clearUpcoming 只保留当前曲目，index 归 0', () {
      final h = Harness();
      h.player.play(song('b'), source: <Map<String, Object?>>[
        song('a'),
        song('b'),
        song('c'),
      ]);
      h.player.clearUpcoming();
      expect(h.player.queueLength, 1);
      expect(h.player.queueIndex, 0);
      expect(h.player.hasQueue, isTrue);
      expect(h.player.queue.items.single['id'], 'b');
      expect(h.player.current['id'], 'b');
    });

    test('removeFromQueue 越界与当前项均无副作用', () {
      final h = Harness();
      h.player.play(song('b'), source: <Map<String, Object?>>[
        song('a'),
        song('b'),
        song('c'),
      ]);
      final beforeQueue = h.player.queueLength;
      final beforeIndex = h.player.queueIndex;
      h.player.removeFromQueue(-1);
      h.player.removeFromQueue(beforeQueue);
      h.player.removeFromQueue(beforeIndex);
      expect(h.player.queueLength, beforeQueue);
      expect(h.player.queueIndex, beforeIndex);
      expect(h.player.queue.items.map((track) => track['id']).toList(),
          <Object?>['a', 'b', 'c']);
    });

    test('removeFromQueue 其他行生效，索引随删除前移', () {
      final h = Harness();
      h.player.play(song('c'), source: <Map<String, Object?>>[
        song('a'),
        song('b'),
        song('c'),
      ]);
      h.player.removeFromQueue(0);
      expect(h.player.queueLength, 2);
      expect(h.player.queueIndex, 1);
      expect(h.player.queue.items.map((track) => track['id']).toList(),
          <Object?>['b', 'c']);
    });
  });

  group('队列读数（queueLength / queueIndex / hasQueue）', () {
    test('空队列：length 0、index -1、hasQueue false', () {
      final h = Harness();
      expect(h.player.queue, isA<PlaybackQueue>());
      expect(h.player.queueLength, 0);
      expect(h.player.queueIndex, -1);
      expect(h.player.hasQueue, isFalse);
    });

    test('装队列后 length/index 跟随队列，selected 行生效', () {
      final h = Harness();
      h.player.queue.replace(<Map<String, Object?>>[
        song('a'),
        song('b'),
        song('c'),
      ]);
      expect(h.player.queueLength, 3);
      expect(h.player.hasQueue, isTrue);
      expect(h.player.queueIndex, -1);
      h.player.queue.select(1);
      expect(h.player.queueIndex, 1);
    });
  });
}
