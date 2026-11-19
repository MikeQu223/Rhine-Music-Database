// DEDUP-04 歌词侧：lyrics_controller.dart 的运行时单测。
//
// 未执行：本任务禁止 flutter test / dart test / dart analyze，测试只按 Qt 原文逐条对照写。
// 权威行号：Qt/src/LyricsController.cpp:60-65（构造/全局偏移）、:78-84（trackKey）、
// :133-146（clear）、:243-254（load 的 sameTrack 分叉）、:470-479（accept）、
// :501-509（sync）、:511-531（adjust/reset）、:534-544（applyGlobalOffset）、
// :639-661（快照）；闸门见 Qt/src/MusicPlayer.cpp:471-492，m_lastPoll 初值见 MusicPlayer.h:64。
//
// 纯 Dart：手写 FakeLyricsPreferencePort（不依赖引擎、不碰文件系统、不 import lib/data），
// 时间由测试显式注入，没有任何定时器。

import 'package:flutter_test/flutter_test.dart';
import 'package:rhine_music_database/domain/lyrics/lyrics_controller.dart';

void main() {
  group('create', () {
    test('没有存过偏移 → 全局 0、当前 0（:60-65 的默认路径）', () async {
      final port = FakeLyricsPreferencePort();
      final controller = await LyricsController.create(port);
      expect(controller.globalOffsetMs, 0.0);
      expect(controller.offsetMs, 0.0);
      expect(controller.status, 'idle');
      expect(controller.message, '');
      expect(controller.currentKey, '');
      expect(controller.index, -1);
      expect(controller.positionMs, 0.0);
      expect(controller.localSource, 'auto');
      expect(controller.document, isEmpty);
      expect(port.readKeys, <String>['lyrics-global-offset-ms']);
    });

    test('存过 2500 → 全局与当前偏移都是 2500（:63-65）', () async {
      final controller = await LyricsController.create(FakeLyricsPreferencePort('2500'));
      expect(controller.globalOffsetMs, 2500.0);
      expect(controller.offsetMs, 2500.0);
    });

    test('不可解析的文本 → 保持 0（:61-62）', () async {
      final controller = await LyricsController.create(FakeLyricsPreferencePort('abc'));
      expect(controller.globalOffsetMs, 0.0);
      expect(controller.offsetMs, 0.0);
    });

    test('超出范围的存量 → 夹到 10000（:63）', () async {
      final controller = await LyricsController.create(FakeLyricsPreferencePort('99999'));
      expect(controller.globalOffsetMs, 10000.0);
      expect(controller.offsetMs, 10000.0);
    });
  });

  group('trackKey', () {
    test('空曲目 → 空串（:79-81）', () {
      expect(LyricsController.trackKey(null), '');
      expect(LyricsController.trackKey(<String, Object?>{}), '');
    });

    test('provider 缺失按 netease、缺 id 留空（:82，Qt 不校验 id）', () {
      expect(LyricsController.trackKey(track('42')), 'netease:42');
      expect(LyricsController.trackKey(<String, Object?>{'provider': 'qq'}), 'qq:');
      expect(LyricsController.trackKey(<String, Object?>{'provider': 7, 'id': '42'}), 'netease:42');
    });

    test('非 local 的 provider 只用 provider:id', () {
      expect(LyricsController.trackKey(track('42', provider: 'qq')), 'qq:42');
      expect(
        LyricsController.trackKey(track('42', provider: 'qq', fingerprint: 'abc')),
        'qq:42',
      );
    });

    test('local 追加 fingerprint（:83）', () {
      expect(
        LyricsController.trackKey(track('7', provider: 'local', fingerprint: 'abc')),
        'local:7:abc',
      );
      expect(LyricsController.trackKey(track('7', provider: 'local')), 'local:7:');
    });
  });

  group('load / sameTrack', () {
    test('首次加载：清空文档、偏移取全局、位置归零、发一次 changed（:243-254）', () async {
      final controller = await LyricsController.create(FakeLyricsPreferencePort('2500'));
      var changes = 0;
      controller.addListener(() {
        changes += 1;
      });
      controller.load(track('1'));
      expect(controller.currentKey, 'netease:1');
      expect(controller.offsetMs, 2500.0);
      expect(controller.positionMs, 0.0);
      expect(controller.status, 'idle');
      expect(controller.message, '');
      expect(controller.index, -1);
      expect(controller.document, isEmpty);
      expect(changes, 1);
    });

    test('同曲再加载：保留每曲偏移与播放位置（:248-250）', () async {
      final controller = await LyricsController.create(FakeLyricsPreferencePort());
      controller.load(track('1'));
      controller.tick(0.0, positionMs: 5000);
      controller.adjustOffset(200);
      controller.load(track('1'));
      expect(controller.offsetMs, 200.0);
      expect(controller.positionMs, 5000.0);
      expect(controller.currentKey, 'netease:1');
    });

    test('换曲：偏移回到全局值、位置归零（:249-250）', () async {
      final controller = await LyricsController.create(FakeLyricsPreferencePort());
      controller.load(track('1'));
      controller.tick(0.0, positionMs: 5000);
      controller.adjustOffset(200);
      controller.load(track('2'));
      expect(controller.offsetMs, 0.0);
      expect(controller.positionMs, 0.0);
      expect(controller.currentKey, 'netease:2');
    });

    test('local 与在线曲目即使 id 相同也是不同键（:83）', () async {
      final controller = await LyricsController.create(FakeLyricsPreferencePort());
      controller.load(track('7', provider: 'local', fingerprint: 'abc'));
      controller.adjustOffset(400);
      controller.load(track('7', provider: 'local', fingerprint: 'def'));
      expect(controller.currentKey, 'local:7:def');
      expect(controller.offsetMs, 0.0);
    });
  });

  group('accept', () {
    test('有时间轴 → ready、message 清空、按当前位置算活动行（:470-479）', () async {
      final controller = await LyricsController.create(FakeLyricsPreferencePort());
      var changes = 0;
      controller.addListener(() {
        changes += 1;
      });
      controller.accept(lyricsDoc(<double>[1000, 2000, 3000]), track('1'));
      expect(controller.status, 'ready');
      expect(controller.message, '');
      expect(controller.index, -1);
      expect(controller.document['trackKey'], 'netease:1');
      expect((controller.document['lines'] as List<Object?>).length, 3);
      expect(changes, 1);
    });

    test('没有时间轴 → plain 与固定文案（:477-478）', () async {
      final controller = await LyricsController.create(FakeLyricsPreferencePort());
      controller.accept(lyricsDoc(<double>[]), track('1'));
      expect(controller.status, 'plain');
      expect(controller.message, '此歌词没有时间信息');
      expect(controller.index, -1);
    });

    test('接管文档：调用方之后再改入参不影响内部（QJsonObject 值语义，:471-472）', () async {
      final controller = await LyricsController.create(FakeLyricsPreferencePort());
      final doc = lyricsDoc(<double>[0, 1000]);
      controller.accept(doc, track('1'));
      doc['offsetMs'] = 500;
      (doc['lines'] as List<Object?>).add(<String, Object?>{'startMs': 9, 'text': 'z'});
      expect(controller.document['offsetMs'], 0);
      expect((controller.document['lines'] as List<Object?>).length, 2);
    });

    test('活动行同时吃文档偏移与每曲偏移（:479 → :119）', () async {
      final controller = await LyricsController.create(FakeLyricsPreferencePort());
      controller.tick(0.0, positionMs: 1500);
      controller.adjustOffset(600);
      controller.accept(lyricsDoc(<double>[1000, 2000, 3000]), track('1'));
      // 1500 + 0 + 600 = 2100 → 第二行。
      expect(controller.index, 1);
      controller.accept(lyricsDoc(<double>[1000, 2000, 3000], offsetMs: -700), track('1'));
      // 1500 - 700 + 600 = 1400 → 首行。
      expect(controller.index, 0);
    });
  });

  group('sync', () {
    test('位置与活动行同步推进，行不变不发信号（:501-508）', () async {
      final controller = await LyricsController.create(FakeLyricsPreferencePort());
      controller.accept(lyricsDoc(<double>[1000, 2000]), track('1'));
      var changes = 0;
      controller.addListener(() {
        changes += 1;
      });
      controller.sync(1500);
      expect(controller.positionMs, 1500.0);
      expect(controller.index, 0);
      expect(changes, 1);
      controller.sync(1900);
      expect(controller.index, 0);
      expect(changes, 1);
      controller.sync(2000);
      expect(controller.index, 1);
      expect(changes, 2);
    });

    test('时间轴 = position + 文档偏移 + 每曲偏移（:503）', () async {
      final controller = await LyricsController.create(FakeLyricsPreferencePort());
      controller.accept(lyricsDoc(<double>[1000, 1600]), track('1'));
      controller.sync(500);
      expect(controller.index, -1);
      controller.adjustOffset(500);
      // adjustOffset 内部 sync(500)：500 + 0 + 500 = 1000 → 首行。
      expect(controller.index, 0);
    });

    test('没有文档时 startMs 为空，活动行恒为 -1', () async {
      final controller = await LyricsController.create(FakeLyricsPreferencePort());
      controller.sync(99999);
      expect(controller.index, -1);
    });
  });

  group('tick', () {
    test('首个 tick 越过闸门（m_lastPoll 初值 -1，:475、:478）', () async {
      final controller = await LyricsController.create(FakeLyricsPreferencePort());
      controller.accept(lyricsDoc(<double>[0, 1000, 2000]), track('1'));
      expect(controller.tick(0.0, positionMs: 1500), isTrue);
      expect(controller.positionMs, 1500.0);
      expect(controller.index, 1);
    });

    test('0.1 秒内不重复轮询，超过 0.1 才放行（:475）', () async {
      final controller = await LyricsController.create(FakeLyricsPreferencePort());
      controller.accept(lyricsDoc(<double>[0, 1000, 2000]), track('1'));
      expect(controller.tick(0.0, positionMs: 1500), isTrue);
      expect(controller.tick(0.05, positionMs: 1600), isFalse);
      expect(controller.positionMs, 1500.0);
      expect(controller.tick(0.15, positionMs: 2200), isTrue);
      expect(controller.positionMs, 2200.0);
      expect(controller.index, 2);
    });

    test('倒退的 time 被闸门挡住（单调的来源）', () async {
      final controller = await LyricsController.create(FakeLyricsPreferencePort());
      expect(controller.tick(10.0, positionMs: 1500), isTrue);
      expect(controller.tick(9.0, positionMs: 3000), isFalse);
      expect(controller.positionMs, 1500.0);
      expect(controller.tick(10.0, positionMs: 3000), isFalse);
      expect(controller.positionMs, 1500.0);
    });

    test('force 跳过闸门，但仍然记 m_lastPoll（:475-478）', () async {
      final controller = await LyricsController.create(FakeLyricsPreferencePort());
      expect(controller.tick(5.0, positionMs: 1000), isTrue);
      expect(controller.tick(5.01, positionMs: 2000, force: true), isTrue);
      expect(controller.positionMs, 2000.0);
      // force 也写了 m_lastPoll=5.01，所以 5.1 差 0.09 仍被挡，5.11 才放行。
      expect(controller.tick(5.1, positionMs: 2500), isFalse);
      expect(controller.tick(5.11, positionMs: 2500), isTrue);
    });
  });

  group('adjustOffset', () {
    test('累加后夹在 ±10000（:515）', () async {
      final controller = await LyricsController.create(FakeLyricsPreferencePort());
      controller.adjustOffset(15000);
      expect(controller.offsetMs, 10000.0);
      controller.adjustOffset(200);
      expect(controller.offsetMs, 10000.0);
      controller.adjustOffset(-30000);
      expect(controller.offsetMs, -10000.0);
    });

    test('行不变时只发一次信号（:517）', () async {
      final controller = await LyricsController.create(FakeLyricsPreferencePort());
      controller.accept(lyricsDoc(<double>[0, 5000]), track('1'));
      controller.sync(1000);
      var changes = 0;
      controller.addListener(() {
        changes += 1;
      });
      controller.adjustOffset(200);
      expect(controller.offsetMs, 200.0);
      expect(controller.index, 0);
      expect(changes, 1);
    });

    test('行变化时 sync 与末尾各发一次（:507 与 :517，Qt 现状）', () async {
      final controller = await LyricsController.create(FakeLyricsPreferencePort());
      controller.accept(lyricsDoc(<double>[0, 1000, 2000]), track('1'));
      controller.sync(1500);
      var changes = 0;
      controller.addListener(() {
        changes += 1;
      });
      controller.adjustOffset(500);
      // 1500 + 500 = 2000 → 第三行。
      expect(controller.index, 2);
      expect(changes, 2);
    });

    test('不改变 positionMs', () async {
      final controller = await LyricsController.create(FakeLyricsPreferencePort());
      controller.sync(1234);
      controller.adjustOffset(200);
      expect(controller.positionMs, 1234.0);
    });
  });

  group('resetOffset', () {
    test('已经是 0 → 直接返回，不发信号（:525-527）', () async {
      final controller = await LyricsController.create(FakeLyricsPreferencePort());
      var changes = 0;
      controller.addListener(() {
        changes += 1;
      });
      controller.resetOffset();
      expect(controller.offsetMs, 0.0);
      expect(changes, 0);
    });

    test('非 0 → 归零、重算活动行、发信号（:528-530）', () async {
      final controller = await LyricsController.create(FakeLyricsPreferencePort());
      controller.accept(lyricsDoc(<double>[0, 1000, 2000]), track('1'));
      controller.sync(1500);
      controller.adjustOffset(200);
      expect(controller.index, 1);
      var changes = 0;
      controller.addListener(() {
        changes += 1;
      });
      controller.resetOffset();
      expect(controller.offsetMs, 0.0);
      expect(controller.index, 1);
      expect(changes, 1);
    });

    test('归零后行会后退重算', () async {
      final controller = await LyricsController.create(FakeLyricsPreferencePort());
      controller.accept(lyricsDoc(<double>[0, 1000, 2000]), track('1'));
      controller.sync(1500);
      controller.adjustOffset(600);
      expect(controller.index, 2);
      controller.resetOffset();
      expect(controller.index, 1);
    });
  });

  group('applyGlobalOffset', () {
    test('当前偏移与全局相同 → 不写偏好、不发信号（:538-540）', () async {
      final port = FakeLyricsPreferencePort('300');
      final controller = await LyricsController.create(port);
      var changes = 0;
      controller.addListener(() {
        changes += 1;
      });
      await controller.applyGlobalOffset();
      expect(port.writeKeys, isEmpty);
      expect(changes, 0);
      expect(controller.globalOffsetMs, 300.0);
    });

    test('把当前偏移写成全局值并以 QString::number 文本落盘（:541-543）', () async {
      final port = FakeLyricsPreferencePort();
      final controller = await LyricsController.create(port);
      controller.adjustOffset(200);
      var changes = 0;
      controller.addListener(() {
        changes += 1;
      });
      await controller.applyGlobalOffset();
      expect(controller.globalOffsetMs, 200.0);
      expect(port.writeKeys, <String>['lyrics-global-offset-ms']);
      expect(port.writeValues, <String>['200']);
      expect(changes, 1);
    });

    test('非整数偏移按 6 位有效数字写回', () async {
      final port = FakeLyricsPreferencePort();
      final controller = await LyricsController.create(port);
      controller.adjustOffset(1234.5678);
      await controller.applyGlobalOffset();
      expect(port.writeValues, <String>['1234.57']);
    });

    test('不改当前偏移、不重算活动行（:534-544 没有 sync）', () async {
      final controller = await LyricsController.create(FakeLyricsPreferencePort());
      controller.accept(lyricsDoc(<double>[0, 1000, 2000]), track('1'));
      controller.sync(1500);
      controller.adjustOffset(200);
      await controller.applyGlobalOffset();
      expect(controller.offsetMs, 200.0);
      expect(controller.index, 1);
      expect(controller.positionMs, 1500.0);
    });
  });

  group('playbackSnapshot', () {
    test('9 个键齐全（:639-649）', () async {
      final controller = await LyricsController.create(FakeLyricsPreferencePort());
      controller.load(track('1'));
      controller.accept(lyricsDoc(<double>[0, 1000]), track('1'));
      controller.sync(1500);
      controller.adjustOffset(200);
      final snapshot = controller.playbackSnapshot();
      final keys = snapshot.keys.toList()..sort();
      expect(keys, <String>[
        'document',
        'globalOffsetMs',
        'index',
        'key',
        'localSource',
        'message',
        'offsetMs',
        'positionMs',
        'status',
      ]);
      expect(snapshot['status'], 'ready');
      expect(snapshot['message'], '');
      expect(snapshot['key'], 'netease:1');
      expect(snapshot['index'], 1);
      expect(snapshot['offsetMs'], 200.0);
      expect(snapshot['positionMs'], 1500.0);
      expect(snapshot['globalOffsetMs'], 0.0);
      expect(snapshot['localSource'], 'auto');
    });

    test('文档在快照里是深拷贝', () async {
      final controller = await LyricsController.create(FakeLyricsPreferencePort());
      controller.accept(lyricsDoc(<double>[0, 1000]), track('1'));
      final snapshot = controller.playbackSnapshot();
      final document = snapshot['document'] as Map<String, Object?>;
      (document['lines'] as List<Object?>).clear();
      expect((controller.document['lines'] as List<Object?>).length, 2);
    });
  });

  group('applyPlaybackSnapshot', () {
    test('空快照 → 全部默认值、不发信号（:651-660）', () async {
      final controller = await LyricsController.create(FakeLyricsPreferencePort('300'));
      controller.load(track('1'));
      controller.accept(lyricsDoc(<double>[0, 1000]), track('1'));
      var changes = 0;
      controller.addListener(() {
        changes += 1;
      });
      controller.applyPlaybackSnapshot(<String, Object?>{});
      expect(controller.document, isEmpty);
      expect(controller.status, 'idle');
      expect(controller.message, '');
      expect(controller.currentKey, '');
      expect(controller.index, -1);
      expect(controller.offsetMs, 0.0);
      expect(controller.positionMs, 0.0);
      expect(controller.globalOffsetMs, 0.0);
      expect(controller.localSource, 'auto');
      expect(changes, 0);
    });

    test('完整快照逐键恢复', () async {
      final controller = await LyricsController.create(FakeLyricsPreferencePort());
      controller.applyPlaybackSnapshot(<String, Object?>{
        'document': lyricsDoc(<double>[0, 1000]),
        'status': 'ready',
        'message': 'm',
        'key': 'netease:9',
        'index': 1,
        'offsetMs': -300,
        'positionMs': 2500,
        'globalOffsetMs': -100,
        'localSource': 'cache',
      });
      expect(controller.status, 'ready');
      expect(controller.message, 'm');
      expect(controller.currentKey, 'netease:9');
      expect(controller.index, 1);
      expect(controller.offsetMs, -300.0);
      expect(controller.positionMs, 2500.0);
      expect(controller.globalOffsetMs, -100.0);
      expect(controller.localSource, 'cache');
      expect((controller.document['lines'] as List<Object?>).length, 2);
    });

    test('index 走 Qt toInt：非整数/非有限回落 -1（:656 + qjsonvalue.cpp:683-705）', () async {
      final controller = await LyricsController.create(FakeLyricsPreferencePort());
      controller.applyPlaybackSnapshot(<String, Object?>{'index': 1.5});
      expect(controller.index, -1);
      controller.applyPlaybackSnapshot(<String, Object?>{'index': double.nan});
      expect(controller.index, -1);
      controller.applyPlaybackSnapshot(<String, Object?>{'index': double.infinity});
      expect(controller.index, -1);
      controller.applyPlaybackSnapshot(<String, Object?>{'index': -1});
      expect(controller.index, -1);
      controller.applyPlaybackSnapshot(<String, Object?>{'index': 2.0});
      expect(controller.index, 2);
    });

    test('照抄 Qt：只换 document、不重建 starts（:652，见类注释的残余风险）', () async {
      final controller = await LyricsController.create(FakeLyricsPreferencePort());
      controller.accept(lyricsDoc(<double>[0, 1000]), track('1'));
      controller.applyPlaybackSnapshot(<String, Object?>{
        'document': lyricsDoc(<double>[0, 5000], offsetMs: 0),
        'index': 0,
      });
      // 新文档的首行间隔是 5000，但 starts 仍是旧的 [0, 1000]：sync(3000) 落在旧第二行。
      controller.sync(3000);
      expect(controller.index, 1);
    });
  });

  group('clear', () {
    test('回到 idle 空态、偏移退回全局值、不发信号（:133-146）', () async {
      final controller = await LyricsController.create(FakeLyricsPreferencePort('2500'));
      controller.load(track('1'));
      controller.accept(lyricsDoc(<double>[0, 1000]), track('1'));
      controller.tick(0.0, positionMs: 1500);
      controller.adjustOffset(200);
      var changes = 0;
      controller.addListener(() {
        changes += 1;
      });
      controller.clear();
      expect(controller.currentKey, '');
      expect(controller.document, isEmpty);
      expect(controller.status, 'idle');
      expect(controller.message, '');
      expect(controller.index, -1);
      expect(controller.offsetMs, 2500.0);
      expect(controller.positionMs, 0.0);
      expect(changes, 0);
    });
  });

  group('监听器', () {
    test('removeListener 之后不再收到信号', () async {
      final controller = await LyricsController.create(FakeLyricsPreferencePort());
      var changes = 0;
      void listener() {
        changes += 1;
      }
      controller.addListener(listener);
      // load 无条件发 changed（:254 之后 Qt 必进一个会 emit 的分支）。
      controller.load(track('1'));
      expect(changes, 1);
      controller.removeListener(listener);
      controller.load(track('2'));
      expect(changes, 1);
    });
  });
}

class FakeLyricsPreferencePort implements LyricsPreferencePort {
  FakeLyricsPreferencePort([this.stored]);

  String? stored;
  final List<String> readKeys = <String>[];
  final List<String> writeKeys = <String>[];
  final List<String> writeValues = <String>[];

  @override
  Future<String?> read(String key) async {
    readKeys.add(key);
    return stored;
  }

  @override
  Future<void> write(String key, String value) async {
    writeKeys.add(key);
    writeValues.add(value);
    stored = value;
  }
}

Map<String, Object?> track(String id, {String? provider, String? fingerprint}) {
  return <String, Object?>{
    'provider': ?provider,
    'id': id,
    'fingerprint': ?fingerprint,
  };
}

Map<String, Object?> lyricsDoc(List<double> starts, {double offsetMs = 0}) {
  return <String, Object?>{
    'version': 1,
    'timing': 'line',
    'plainText': '',
    'offsetMs': offsetMs,
    'lines': <Object?>[
      for (var i = 0; i < starts.length; i += 1)
        <String, Object?>{'startMs': starts[i], 'text': 'line$i'},
    ],
  };
}