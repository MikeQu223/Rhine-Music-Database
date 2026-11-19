// T23-T02 · 歌词全局偏移、sameTrack 与 localSource 的静态规格测试。
//
// 本文件只静态编写，未运行（本原子禁止任何 dart/flutter 执行）；断言全部来自源码。
//
// 证据（lib/domain/lyrics/lyrics_timeline.dart）：
//   :26       lyricsOffsetLimitMs = 10000
//   :30       lyricsDocumentLineLimit = 5000
//   :34       lyricsTimings = ['line', 'word', 'none']
//   :41-45    clampLyricsOffsetMs（std::clamp 语义，NaN 原样穿过）
//   :63-76    parseLyricsOffsetPreference（trim → tryParse → isFinite → clamp）
//   :88-111   formatLyricsOffsetPreference（QString::number 的 'g' 6 位有效数字语义）
//   :131      lyricsNumberValue
//   :150-168  lyricsIntegerValue（int32 区间 + 整数判定）
//   :175-176  lyricsTextValue
//   :182-192  lyricsObjectValue
//   :208-228  validLyricsDocument
//   :235-243  lyricsDocumentStarts（保持文档顺序，不排序）
//   :246-247  lyricsDocumentOffsetMs
//   :256-268  lyricsLineIndexAt（upper_bound，不校验升序）
//   :278-285  lyricsActiveLineIndex
//   :292-296  copyLyricsDocument
//
// 证据（lib/domain/lyrics/lyrics_controller.dart）：
//   :77-82    create（读偏好，解析失败保持 0）
//   :154-164  trackKey（provider 缺省 netease，local 追加 fingerprint）
//   :173-182  clear（不发信号）
//   :197-207  load（sameTrack 决定 position/offset，emit 一次）
//   :219-228  accept（深拷贝、trackKey、status/message、活动行）
//   :235-243  sync（只在新活动行变化时 emit）
//   :261-268  tick（0.1 秒闸门，force 跳过但仍记录）
//   :276-280  adjustOffset（累加后 clamp，sync + 无条件 emit）
//   :286-293  resetOffset（已是 0 时不发信号）
//   :304-318  applyGlobalOffset（相同则 no-op；写失败仍 emit 并抛出）
//   :325-337  playbackSnapshot（9 键）
//   :350-360  applyPlaybackSnapshot（QJson 默认值，不发信号）
//
// Qt 对照（只作语义核对，不执行）：Qt/src/LyricsController.cpp:60-64（读取与夹取）、
// :243-254（sameTrack）、:470-479（accept）、:501-509（sync）、:511-531（adjust/reset）、
// :534-544（applyGlobalOffset）、:639-661（快照）。Qt 的 selectLocalSource 白名单
// {"auto","local","netease","qq","kugou"} 与 PROVIDERS{"netease","qq","kugou","siren"}
// 属数据层；Dart 层没有对应 API，只保留 localSource 字段（仅由快照恢复改写），
// 该差异记录在报告，不写成期望。

import 'package:flutter_test/flutter_test.dart';
import 'package:rhine_music_database/domain/lyrics/lyrics_controller.dart';
import 'package:rhine_music_database/domain/lyrics/lyrics_timeline.dart';

/// 合法歌词文档：默认三行，startMs 为 [0, 1000, 2000]。
Map<String, Object?> lyricsDoc({
  List<double> starts = const <double>[0, 1000, 2000],
  double offsetMs = 0,
  String timing = 'line',
}) {
  return <String, Object?>{
    'version': 1,
    'timing': timing,
    'plainText': 'plain',
    'offsetMs': offsetMs,
    'lines': <Map<String, Object?>>[
      for (var i = 0; i < starts.length; i++)
        <String, Object?>{'startMs': starts[i], 'text': 'L$i'},
    ],
  };
}

Map<String, Object?> track(
  String id, {
  String provider = 'netease',
  String? fingerprint,
}) {
  return <String, Object?>{
    'kind': 'song',
    'id': id,
    'provider': provider,
    'fingerprint': ?fingerprint,
  };
}

class FakeLyricsPreferences implements LyricsPreferencePort {
  FakeLyricsPreferences([this.value]);

  String? value;
  final List<String> readKeys = <String>[];
  final List<MapEntry<String, String>> writes = <MapEntry<String, String>>[];
  Object? writeError;

  @override
  Future<String?> read(String key) async {
    readKeys.add(key);
    return value;
  }

  @override
  Future<void> write(String key, String value) async {
    if (writeError != null) {
      throw writeError!;
    }
    writes.add(MapEntry<String, String>(key, value));
  }
}

Future<(LyricsController, FakeLyricsPreferences)> makeController([
  String? saved,
]) async {
  final preferences = FakeLyricsPreferences(saved);
  final controller = await LyricsController.create(preferences);
  return (controller, preferences);
}

void main() {
  group('常量与偏好键', () {
    test('偏移边界为 10000 毫秒、行数上限 5000、timing 三种取值', () {
      expect(lyricsOffsetLimitMs, 10000);
      expect(lyricsDocumentLineLimit, 5000);
      expect(lyricsTimings, <String>['line', 'word', 'none']);
      expect(lyricsGlobalOffsetPreferenceKey, 'lyrics-global-offset-ms');
      expect(LyricsController.tickIntervalSeconds, 0.1);
    });
  });

  group('clampLyricsOffsetMs', () {
    test('区间内原样返回', () {
      expect(clampLyricsOffsetMs(0), 0);
      expect(clampLyricsOffsetMs(1234.5), 1234.5);
      expect(clampLyricsOffsetMs(-1234.5), -1234.5);
      expect(clampLyricsOffsetMs(10000), 10000);
      expect(clampLyricsOffsetMs(-10000), -10000);
    });

    test('越界夹到上下界', () {
      expect(clampLyricsOffsetMs(10000.5), 10000);
      expect(clampLyricsOffsetMs(99999), 10000);
      expect(clampLyricsOffsetMs(-10000.5), -10000);
      expect(clampLyricsOffsetMs(-99999), -10000);
    });

    test('NaN 原样穿过，±Inf 被夹取', () {
      expect(clampLyricsOffsetMs(double.nan).isNaN, isTrue);
      expect(clampLyricsOffsetMs(double.infinity), 10000);
      expect(clampLyricsOffsetMs(double.negativeInfinity), -10000);
    });
  });

  group('parseLyricsOffsetPreference', () {
    test('缺失、空白与非法文本都返回 null', () {
      expect(parseLyricsOffsetPreference(null), isNull);
      expect(parseLyricsOffsetPreference(''), isNull);
      expect(parseLyricsOffsetPreference('   '), isNull);
      expect(parseLyricsOffsetPreference('abc'), isNull);
      expect(parseLyricsOffsetPreference('12ms'), isNull);
    });

    test('非有限文本被 isFinite 拒绝', () {
      expect(parseLyricsOffsetPreference('NaN'), isNull);
      expect(parseLyricsOffsetPreference('Infinity'), isNull);
      expect(parseLyricsOffsetPreference('-Infinity'), isNull);
      expect(parseLyricsOffsetPreference('inf'), isNull);
    });

    test('去空白后解析并夹取', () {
      expect(parseLyricsOffsetPreference(' 200 '), 200);
      expect(parseLyricsOffsetPreference('0'), 0);
      expect(parseLyricsOffsetPreference('12345'), 10000);
      expect(parseLyricsOffsetPreference('-12345'), -10000);
      expect(parseLyricsOffsetPreference('1e4'), 10000);
      expect(parseLyricsOffsetPreference('-0.0'), 0);
    });
  });

  group('formatLyricsOffsetPreference', () {
    test('非有限值使用 printf 小写拼写', () {
      expect(formatLyricsOffsetPreference(double.nan), 'nan');
      expect(formatLyricsOffsetPreference(double.infinity), 'inf');
      expect(formatLyricsOffsetPreference(double.negativeInfinity), '-inf');
    });

    test('定点分支去尾零并保留必要小数', () {
      expect(formatLyricsOffsetPreference(0), '0');
      expect(formatLyricsOffsetPreference(200), '200');
      expect(formatLyricsOffsetPreference(-200), '-200');
      expect(formatLyricsOffsetPreference(10000), '10000');
      expect(formatLyricsOffsetPreference(-10000), '-10000');
      expect(formatLyricsOffsetPreference(1234.5678), '1234.57');
      expect(formatLyricsOffsetPreference(-12.345678), '-12.3457');
      expect(formatLyricsOffsetPreference(0.0001), '0.0001');
    });

    test('指数分支用于 |value| < 1e-4 或 >= 1e6', () {
      expect(formatLyricsOffsetPreference(0.00001), '1e-05');
      expect(formatLyricsOffsetPreference(0.000012345), '1.2345e-05');
      expect(formatLyricsOffsetPreference(1000000), '1e+06');
      expect(formatLyricsOffsetPreference(999999), '999999');
    });
  });

  group('QJson 值语义', () {
    test('lyricsNumberValue 非数值为 0，int 转 double', () {
      expect(lyricsNumberValue(null), 0);
      expect(lyricsNumberValue('3'), 0);
      expect(lyricsNumberValue(<Object?>[]), 0);
      expect(lyricsNumberValue(3), 3.0);
      expect(lyricsNumberValue(-2.5), -2.5);
      expect(lyricsNumberValue(3), isA<double>());
    });

    test('lyricsIntegerValue 只接受 int32 内的整数', () {
      expect(lyricsIntegerValue(1), 1);
      expect(lyricsIntegerValue(1.0), 1);
      expect(lyricsIntegerValue(2147483647), 2147483647);
      expect(lyricsIntegerValue(2147483647.0), 2147483647);
      expect(lyricsIntegerValue(-2147483648), -2147483648);
      expect(lyricsIntegerValue(-2147483648.0), -2147483648);
    });

    test('lyricsIntegerValue 的非法输入回落到 fallback', () {
      expect(lyricsIntegerValue(1.5), 0);
      expect(lyricsIntegerValue(1.5, fallback: -1), -1);
      expect(lyricsIntegerValue(2147483648), 0);
      expect(lyricsIntegerValue(2147483648.0), 0);
      expect(lyricsIntegerValue(-2147483649), 0);
      expect(lyricsIntegerValue(double.nan, fallback: 7), 7);
      expect(lyricsIntegerValue(double.infinity), 0);
      expect(lyricsIntegerValue('1'), 0);
      expect(lyricsIntegerValue(null, fallback: -1), -1);
    });

    test('lyricsTextValue 非字符串回落', () {
      expect(lyricsTextValue('x'), 'x');
      expect(lyricsTextValue(1), '');
      expect(lyricsTextValue(null, fallback: 'idle'), 'idle');
    });

    test('lyricsObjectValue 原样返回同类型 Map，其它 Map 键转字符串', () {
      final Map<String, Object?> same = <String, Object?>{'a': 1};
      expect(identical(lyricsObjectValue(same), same), isTrue);
      expect(
        lyricsObjectValue(<Object?, Object?>{1: 'x', 'b': 2}),
        <String, Object?>{'1': 'x', 'b': 2},
      );
      expect(lyricsObjectValue(null), isEmpty);
      expect(lyricsObjectValue(<Object?>[]), isEmpty);
      expect(lyricsObjectValue('x'), isEmpty);
    });
  });

  group('validLyricsDocument', () {
    test('版本 1.0 的整数语义合法，1.5 非法', () {
      expect(validLyricsDocument(lyricsDoc()), isTrue);
      final doubleVersion = lyricsDoc()..['version'] = 1.0;
      expect(validLyricsDocument(doubleVersion), isTrue);
      final fractional = lyricsDoc()..['version'] = 1.5;
      expect(validLyricsDocument(fractional), isFalse);
      final textVersion = lyricsDoc()..['version'] = '1';
      expect(validLyricsDocument(textVersion), isFalse);
    });

    test('timing 必须是三种取值之一，plainText 必须是字符串', () {
      expect(validLyricsDocument(lyricsDoc(timing: 'word')), isTrue);
      expect(validLyricsDocument(lyricsDoc(timing: 'none')), isTrue);
      expect(validLyricsDocument(lyricsDoc(timing: 'karaoke')), isFalse);
      expect(validLyricsDocument(lyricsDoc(timing: '')), isFalse);
      final noText = lyricsDoc()..['plainText'] = 1;
      expect(validLyricsDocument(noText), isFalse);
    });

    test('offsetMs 必须是有限数值', () {
      expect(validLyricsDocument(lyricsDoc(offsetMs: 500)), isTrue);
      expect(
        validLyricsDocument(lyricsDoc()..['offsetMs'] = double.nan),
        isFalse,
      );
      expect(
        validLyricsDocument(lyricsDoc()..['offsetMs'] = double.infinity),
        isFalse,
      );
      expect(validLyricsDocument(lyricsDoc()..['offsetMs'] = '0'), isFalse);
      expect(validLyricsDocument(lyricsDoc()..['offsetMs'] = null), isFalse);
    });

    test('lines 必须是数组且不超过 5000 行', () {
      final empty = lyricsDoc(starts: const <double>[]);
      expect(validLyricsDocument(empty), isTrue);
      final full = <Map<String, Object?>>[
        for (var i = 0; i < 5000; i++) <String, Object?>{'startMs': i, 'text': 'x'},
      ];
      expect(validLyricsDocument(lyricsDoc()..['lines'] = full), isTrue);
      final tooMany = <Map<String, Object?>>[
        for (var i = 0; i < 5001; i++) <String, Object?>{'startMs': i, 'text': 'x'},
      ];
      expect(validLyricsDocument(lyricsDoc()..['lines'] = tooMany), isFalse);
      expect(validLyricsDocument(lyricsDoc()..['lines'] = 'x'), isFalse);
    });

    test('行元素必须是含有限 startMs 与字符串 text 的对象', () {
      final badStart = lyricsDoc()
        ..['lines'] = <Object?>[
          <String, Object?>{'startMs': '0', 'text': 'a'},
        ];
      expect(validLyricsDocument(badStart), isFalse);
      final nanStart = lyricsDoc()
        ..['lines'] = <Object?>[
          <String, Object?>{'startMs': double.nan, 'text': 'a'},
        ];
      expect(validLyricsDocument(nanStart), isFalse);
      final badText = lyricsDoc()
        ..['lines'] = <Object?>[
          <String, Object?>{'startMs': 0, 'text': 1},
        ];
      expect(validLyricsDocument(badText), isFalse);
      final notObject = lyricsDoc()..['lines'] = <Object?>['x'];
      expect(validLyricsDocument(notObject), isFalse);
      final missingStart = lyricsDoc()
        ..['lines'] = <Object?>[
          <String, Object?>{'text': 'a'},
        ];
      expect(validLyricsDocument(missingStart), isFalse);
    });
  });

  group('starts 与活动行', () {
    test('lyricsDocumentStarts 保持文档顺序且不排序', () {
      final doc = lyricsDoc(starts: const <double>[2000, 0, 1000]);
      expect(lyricsDocumentStarts(doc), <double>[2000, 0, 1000]);
      final ints = <String, Object?>{
        'lines': <Object?>[
          <String, Object?>{'startMs': 0, 'text': 'a'},
          <String, Object?>{'startMs': 1500, 'text': 'b'},
        ],
      };
      expect(lyricsDocumentStarts(ints), <double>[0, 1500]);
    });

    test('lyricsDocumentStarts 对非数组与非数值的兜底', () {
      expect(lyricsDocumentStarts(<String, Object?>{}), isEmpty);
      expect(lyricsDocumentStarts(<String, Object?>{'lines': 'x'}), isEmpty);
      final doc = <String, Object?>{
        'lines': <Object?>[
          <String, Object?>{'startMs': '0', 'text': 'a'},
          <String, Object?>{'startMs': 1000, 'text': 'b'},
        ],
      };
      expect(lyricsDocumentStarts(doc), <double>[0, 1000]);
    });

    test('lyricsLineIndexAt 的边界与 NaN', () {
      const starts = <double>[0, 1000, 2000];
      expect(lyricsLineIndexAt(starts, -1), -1);
      expect(lyricsLineIndexAt(starts, 0), 0);
      expect(lyricsLineIndexAt(starts, 999.999), 0);
      expect(lyricsLineIndexAt(starts, 1000), 1);
      expect(lyricsLineIndexAt(starts, 2000), 2);
      expect(lyricsLineIndexAt(starts, 2500), 2);
      expect(lyricsLineIndexAt(starts, double.nan), -1);
      expect(lyricsLineIndexAt(const <double>[], 0), -1);
    });

    test('lyricsLineIndexAt 对重复值与未排序输入按 upper_bound 处理', () {
      expect(lyricsLineIndexAt(const <double>[0, 0, 1000], 0), 1);
      expect(lyricsLineIndexAt(const <double>[2000, 0, 1000], 500), 1);
      expect(lyricsLineIndexAt(const <double>[2000, 0, 1000], 1500), 2);
    });

    test('lyricsActiveLineIndex 叠加文档偏移与参数偏移', () {
      final doc = lyricsDoc(offsetMs: 200);
      expect(lyricsActiveLineIndex(doc, 900), 1);
      expect(lyricsActiveLineIndex(doc, 900, offsetMs: -200), 0);
      expect(lyricsActiveLineIndex(doc, 900, offsetMs: -2000), -1);
      expect(lyricsActiveLineIndex(doc, 1800), 2);
      expect(lyricsActiveLineIndex(<String, Object?>{}, 1000), -1);
    });
  });

  group('copyLyricsDocument', () {
    test('嵌套 Map/List 是深拷贝', () {
      final source = <String, Object?>{
        'a': <String, Object?>{
          'b': <Object?>[1, 2],
        },
      };
      final copy = copyLyricsDocument(source);
      ((copy['a'] as Map<String, Object?>)['b'] as List<Object?>).add(3);
      expect(
        (source['a'] as Map<String, Object?>)['b'],
        <Object?>[1, 2],
      );
      expect(copy['a'], isNot(same(source['a'])));
    });

    test('嵌套的非常规键统一转成字符串', () {
      final source = <String, Object?>{
        'a': <Object?, Object?>{1: 'x'},
      };
      final copy = copyLyricsDocument(source);
      expect(copy['a'], <String, Object?>{'1': 'x'});
    });

    test('标量叶子保持原值', () {
      final source = <String, Object?>{'n': 1, 's': 'x', 'b': true, 'z': null};
      expect(copyLyricsDocument(source), source);
    });
  });

  group('create 与 trackKey', () {
    test('create 读取裸键并把偏好夹到 ±10000', () async {
      final (controller, preferences) = await makeController('250');
      expect(preferences.readKeys, <String>[lyricsGlobalOffsetPreferenceKey]);
      expect(controller.globalOffsetMs, 250);
      expect(controller.offsetMs, 250);
      final (high, _) = await makeController('12345');
      expect(high.globalOffsetMs, 10000);
      expect(high.offsetMs, 10000);
      final (low, _) = await makeController('-12345');
      expect(low.globalOffsetMs, -10000);
    });

    test('create 对缺失与非法偏好保持 0', () async {
      final (missing, _) = await makeController();
      expect(missing.globalOffsetMs, 0);
      expect(missing.offsetMs, 0);
      final (invalid, _) = await makeController('oops');
      expect(invalid.globalOffsetMs, 0);
      final (blank, _) = await makeController('   ');
      expect(blank.globalOffsetMs, 0);
      final (notFinite, _) = await makeController('NaN');
      expect(notFinite.globalOffsetMs, 0);
    });

    test('create 之后的初始状态', () async {
      final (controller, _) = await makeController('250');
      expect(controller.currentKey, '');
      expect(controller.document, isEmpty);
      expect(controller.index, -1);
      expect(controller.positionMs, 0);
      expect(controller.status, 'idle');
      expect(controller.message, '');
      expect(controller.localSource, 'auto');
    });

    test('trackKey 的 provider 缺省与 local fingerprint 规则', () {
      expect(LyricsController.trackKey(null), '');
      expect(LyricsController.trackKey(<String, Object?>{}), '');
      expect(LyricsController.trackKey(track('1')), 'netease:1');
      expect(
        LyricsController.trackKey(track('2', provider: 'qq')),
        'qq:2',
      );
      expect(
        LyricsController.trackKey(
          track('3', provider: 'local', fingerprint: 'abc'),
        ),
        'local:3:abc',
      );
      expect(
        LyricsController.trackKey(track('4', provider: 'local')),
        'local:4:',
      );
    });

    test('trackKey 不校验 id，非字符串按空串', () {
      expect(
        LyricsController.trackKey(<String, Object?>{'provider': 'qq'}),
        'qq:',
      );
      expect(
        LyricsController.trackKey(<String, Object?>{'id': 1}),
        'netease:',
      );
      expect(
        LyricsController.trackKey(<String, Object?>{'provider': 1, 'id': '7'}),
        'netease:7',
      );
    });
  });

  group('clear 与 load', () {
    test('clear 重置全部字段且不发信号', () async {
      final (controller, _) = await makeController('250');
      controller.accept(lyricsDoc(), track('a'));
      controller.sync(1200);
      controller.adjustOffset(200);
      expect(controller.offsetMs, 450);
      var emits = 0;
      controller.addListener(() {
        emits += 1;
      });
      controller.clear();
      expect(controller.currentKey, '');
      expect(controller.document, isEmpty);
      expect(controller.status, 'idle');
      expect(controller.message, '');
      expect(controller.index, -1);
      expect(controller.offsetMs, 250, reason: '回到全局偏移');
      expect(controller.positionMs, 0);
      expect(emits, 0);
    });

    test('load 新曲目：偏移退回全局、位置归零、文档清空并 emit 一次', () async {
      final (controller, _) = await makeController('250');
      controller.load(track('a'));
      controller.accept(lyricsDoc(), track('a'));
      controller.sync(1200);
      controller.adjustOffset(200);
      var emits = 0;
      controller.addListener(() {
        emits += 1;
      });
      controller.load(track('b'));
      expect(controller.currentKey, 'netease:b');
      expect(controller.offsetMs, 250);
      expect(controller.positionMs, 0);
      expect(controller.document, isEmpty);
      expect(controller.index, -1);
      expect(controller.status, 'idle');
      expect(emits, 1);
    });

    test('load 同曲：保留 position 与每曲 offset，但仍清空文档', () async {
      final (controller, _) = await makeController('250');
      controller.load(track('a'));
      controller.accept(lyricsDoc(), track('a'));
      controller.sync(1200);
      controller.adjustOffset(50);
      expect(controller.offsetMs, 300);
      var emits = 0;
      controller.addListener(() {
        emits += 1;
      });
      controller.load(track('a'));
      expect(controller.currentKey, 'netease:a');
      expect(controller.positionMs, 1200);
      expect(controller.offsetMs, 300);
      expect(controller.document, isEmpty);
      expect(controller.index, -1);
      expect(controller.status, 'idle');
      expect(emits, 1);
    });

    test('load 的 sameTrack 由完整 trackKey 决定', () async {
      final (controller, _) = await makeController();
      controller.load(track('a'));
      controller.accept(lyricsDoc(), track('a'));
      controller.sync(1200);
      controller.adjustOffset(100);
      expect(controller.offsetMs, 100);
      controller.load(track('a', provider: 'qq'));
      expect(controller.currentKey, 'qq:a');
      expect(controller.positionMs, 0);
      expect(controller.offsetMs, 0);
      controller.load(track('a'));
      controller.sync(700);
      controller.adjustOffset(30);
      controller.load(track('a', provider: 'local', fingerprint: 'f'));
      expect(controller.currentKey, 'local:a:f');
      expect(controller.positionMs, 0);
      expect(controller.offsetMs, 0);
    });

    test('load 空 track 得到空键并保持 sameTrack 分支', () async {
      final (controller, _) = await makeController();
      controller.load(<String, Object?>{});
      expect(controller.currentKey, '');
      expect(controller.offsetMs, 0);
    });
  });

  group('accept', () {
    test('写入 trackKey、重建 starts 并给出 ready 状态', () async {
      final (controller, _) = await makeController();
      controller.load(track('a'));
      var emits = 0;
      controller.addListener(() {
        emits += 1;
      });
      final source = lyricsDoc();
      controller.accept(source, track('a'));
      expect(controller.document['trackKey'], 'netease:a');
      expect(source.containsKey('trackKey'), isFalse, reason: '调用方文档不被改写');
      expect(controller.status, 'ready');
      expect(controller.message, '');
      expect(controller.index, 0);
      expect(emits, 1);
    });

    test('无行时间轴进入 plain 状态与提示文案', () async {
      final (controller, _) = await makeController();
      controller.load(track('a'));
      controller.accept(lyricsDoc(starts: const <double>[]), track('a'));
      expect(controller.status, 'plain');
      expect(controller.message, '此歌词没有时间信息');
      expect(controller.index, -1);
    });

    test('accept 深拷贝文档，调用方后续修改不影响控制器', () async {
      final (controller, _) = await makeController();
      final source = lyricsDoc();
      controller.accept(source, track('a'));
      final sourceLines = source['lines'] as List<Object?>;
      (sourceLines.first as Map<String, Object?>)['text'] = 'mutated';
      final lines = controller.document['lines'] as List<Object?>;
      expect((lines.first as Map<String, Object?>)['text'], 'L0');
    });

    test('accept 用当前 position 与 offset 计算活动行', () async {
      final (controller, _) = await makeController();
      controller.load(track('a'));
      controller.sync(900);
      controller.accept(lyricsDoc(offsetMs: 200), track('a'));
      expect(controller.index, 1, reason: '900 + 200 = 1100');
      controller.sync(900);
      controller.adjustOffset(-200);
      expect(controller.index, 0, reason: '900 + 200 - 200 = 900');
    });
  });

  group('sync 与 tick', () {
    test('sync 只在活动行变化时 emit，但每次都更新 position', () async {
      final (controller, _) = await makeController();
      controller.accept(lyricsDoc(), track('a'));
      var emits = 0;
      controller.addListener(() {
        emits += 1;
      });
      controller.sync(0);
      expect(controller.positionMs, 0);
      expect(controller.index, 0);
      expect(emits, 0);
      controller.sync(1000);
      expect(controller.index, 1);
      expect(emits, 1);
      controller.sync(1100);
      expect(controller.positionMs, 1100);
      expect(controller.index, 1);
      expect(emits, 1);
      controller.sync(2000);
      expect(controller.index, 2);
      expect(emits, 2);
    });

    test('sync 叠加文档级 offsetMs 与当前 offsetMs', () async {
      final (controller, _) = await makeController();
      controller.accept(lyricsDoc(offsetMs: 500), track('a'));
      controller.sync(600);
      expect(controller.index, 1, reason: '600 + 500 = 1100');
      controller.adjustOffset(-500);
      controller.sync(600);
      expect(controller.index, 0, reason: '600 + 500 - 500 = 600');
    });

    test('sync 空文档恒为 -1', () async {
      final (controller, _) = await makeController();
      controller.sync(5000);
      expect(controller.index, -1);
      expect(controller.positionMs, 5000);
    });

    test('tick 的 0.1 秒闸门', () async {
      final (controller, _) = await makeController();
      expect(controller.tick(0, positionMs: 0), isTrue, reason: '首位 -1');
      expect(controller.tick(0.05, positionMs: 100), isFalse);
      expect(controller.tick(0.099, positionMs: 100), isFalse);
      expect(controller.tick(0.1, positionMs: 200), isTrue);
      expect(controller.tick(0.1, positionMs: 300), isFalse);
      expect(controller.tick(0.0, positionMs: 400), isFalse, reason: '时间倒退');
    });

    test('tick force 跳过闸门但仍记录 lastPoll', () async {
      final (controller, _) = await makeController();
      expect(controller.tick(5, positionMs: 0, force: true), isTrue);
      expect(controller.tick(5.05, positionMs: 100), isFalse);
      expect(controller.tick(5.099, positionMs: 100), isFalse);
      expect(
        controller.tick(5.1, positionMs: 200),
        isFalse,
        reason: 'double 下 5.1 - 5.0 = 0.09999999999999964，仍小于 0.1',
      );
      expect(controller.tick(5.2, positionMs: 300), isTrue);
    });

    test('tick 把 position 交给 sync 并驱动活动行', () async {
      final (controller, _) = await makeController();
      controller.accept(lyricsDoc(), track('a'));
      expect(controller.tick(0, positionMs: 1500), isTrue);
      expect(controller.positionMs, 1500);
      expect(controller.index, 1);
      expect(controller.tick(0.2, positionMs: 2000, force: true), isTrue);
      expect(controller.index, 2);
    });
  });

  group('adjustOffset', () {
    test('累加并夹在 ±10000', () async {
      final (controller, _) = await makeController();
      controller.adjustOffset(200);
      expect(controller.offsetMs, 200);
      controller.adjustOffset(200);
      expect(controller.offsetMs, 400);
      controller.adjustOffset(20000);
      expect(controller.offsetMs, 10000);
      controller.adjustOffset(-30000);
      expect(controller.offsetMs, -10000);
    });

    test('活动行变化时发出两次信号（sync 一次 + 无条件一次）', () async {
      final (controller, _) = await makeController();
      controller.accept(lyricsDoc(), track('a'));
      controller.sync(900);
      var emits = 0;
      controller.addListener(() {
        emits += 1;
      });
      controller.adjustOffset(200);
      expect(controller.index, 1);
      expect(emits, 2);
    });

    test('活动行不变时仍无条件发一次信号', () async {
      final (controller, _) = await makeController();
      controller.accept(lyricsDoc(), track('a'));
      controller.sync(2000);
      var emits = 0;
      controller.addListener(() {
        emits += 1;
      });
      controller.adjustOffset(0);
      expect(controller.offsetMs, 0);
      expect(controller.index, 2);
      expect(emits, 1);
    });

    test('adjustOffset 不改变 positionMs', () async {
      final (controller, _) = await makeController();
      controller.accept(lyricsDoc(), track('a'));
      controller.sync(900);
      controller.adjustOffset(300);
      expect(controller.positionMs, 900);
      expect(controller.offsetMs, 300);
    });
  });

  group('resetOffset', () {
    test('已是 0 时直接返回且不发信号', () async {
      final (controller, _) = await makeController();
      var emits = 0;
      controller.addListener(() {
        emits += 1;
      });
      controller.resetOffset();
      expect(controller.offsetMs, 0);
      expect(emits, 0);
    });

    test('非 0 时归零并重算活动行', () async {
      final (controller, _) = await makeController();
      controller.accept(lyricsDoc(), track('a'));
      controller.sync(900);
      controller.adjustOffset(300);
      expect(controller.index, 1);
      var emits = 0;
      controller.addListener(() {
        emits += 1;
      });
      controller.resetOffset();
      expect(controller.offsetMs, 0);
      expect(controller.index, 0, reason: '900 回到第 0 行');
      expect(emits, 2, reason: 'sync 变行 + 无条件');
      controller.resetOffset();
      expect(emits, 2, reason: '重复 reset 不发信号');
    });
  });

  group('applyGlobalOffset', () {
    test('与全局偏移相同时不写偏好、不发信号', () async {
      final (controller, prefs) = await makeController('250');
      var emits = 0;
      controller.addListener(() {
        emits += 1;
      });
      await controller.applyGlobalOffset();
      expect(prefs.writes, isEmpty);
      expect(emits, 0);
      expect(controller.globalOffsetMs, 250);
    });

    test('变化时写回 QString::number 文本并只发一次信号', () async {
      final (controller, prefs) = await makeController('250');
      controller.adjustOffset(150);
      var emits = 0;
      controller.addListener(() {
        emits += 1;
      });
      await controller.applyGlobalOffset();
      expect(prefs.writes.length, 1);
      expect(prefs.writes.single.key, lyricsGlobalOffsetPreferenceKey);
      expect(prefs.writes.single.value, '400');
      expect(controller.globalOffsetMs, 400);
      expect(controller.offsetMs, 400);
      expect(emits, 1);
    });

    test('applyGlobalOffset 不 sync，活动行与 position 保持', () async {
      final (controller, _) = await makeController();
      controller.accept(lyricsDoc(), track('a'));
      controller.sync(900);
      controller.adjustOffset(400);
      expect(controller.index, 1);
      await controller.applyGlobalOffset();
      expect(controller.positionMs, 900);
      expect(controller.index, 1);
    });

    test('写偏好失败仍更新内存并 emit，同时把异常抛出', () async {
      final (controller, prefs) = await makeController('250');
      controller.adjustOffset(150);
      prefs.writeError = StateError('disk full');
      var emits = 0;
      controller.addListener(() {
        emits += 1;
      });
      await expectLater(controller.applyGlobalOffset(), throwsStateError);
      expect(controller.globalOffsetMs, 400);
      expect(emits, 1);
      expect(prefs.writes, isEmpty, reason: '失败前不落盘');
    });

    test('连续两次 apply 的第二次是 no-op', () async {
      final (controller, prefs) = await makeController();
      controller.adjustOffset(200);
      await controller.applyGlobalOffset();
      expect(prefs.writes.length, 1);
      await controller.applyGlobalOffset();
      expect(prefs.writes.length, 1);
    });
  });

  group('playbackSnapshot', () {
    test('恰好 9 个键且值对应当前状态', () async {
      final (controller, _) = await makeController('250');
      controller.load(track('a'));
      controller.accept(lyricsDoc(offsetMs: 100), track('a'));
      controller.sync(1200);
      controller.adjustOffset(50);
      final snapshot = controller.playbackSnapshot();
      expect(snapshot.keys.toSet(), <String>{
        'document',
        'status',
        'message',
        'key',
        'index',
        'offsetMs',
        'positionMs',
        'globalOffsetMs',
        'localSource',
      });
      expect(snapshot['status'], 'ready');
      expect(snapshot['message'], '');
      expect(snapshot['key'], 'netease:a');
      expect(snapshot['index'], 1);
      expect(snapshot['offsetMs'], 300);
      expect(snapshot['positionMs'], 1200);
      expect(snapshot['globalOffsetMs'], 250);
      expect(snapshot['localSource'], 'auto');
      expect(snapshot['document'], controller.document);
    });

    test('document 是深拷贝，改快照不影响控制器', () async {
      final (controller, _) = await makeController();
      controller.accept(lyricsDoc(), track('a'));
      final snapshot = controller.playbackSnapshot();
      final copy = snapshot['document'] as Map<String, Object?>;
      copy['trackKey'] = 'hacked';
      (copy['lines'] as List<Object?>).clear();
      expect(controller.document['trackKey'], 'netease:a');
      expect((controller.document['lines'] as List<Object?>).length, 3);
    });

    test('保留宿主写入的失败状态与文案', () async {
      final (controller, _) = await makeController();
      controller.accept(lyricsDoc(), track('a'));
      controller.status = 'empty';
      controller.message = '加载失败';
      final snapshot = controller.playbackSnapshot();
      expect(snapshot['status'], 'empty');
      expect(snapshot['message'], '加载失败');
    });
  });

  group('applyPlaybackSnapshot', () {
    test('空快照全部取默认值且不发信号', () async {
      final (controller, _) = await makeController();
      var emits = 0;
      controller.addListener(() {
        emits += 1;
      });
      controller.applyPlaybackSnapshot(<String, Object?>{});
      expect(controller.document, isEmpty);
      expect(controller.status, 'idle');
      expect(controller.message, '');
      expect(controller.currentKey, '');
      expect(controller.index, -1);
      expect(controller.offsetMs, 0);
      expect(controller.positionMs, 0);
      expect(controller.globalOffsetMs, 0);
      expect(controller.localSource, 'auto');
      expect(emits, 0);
    });

    test('逐键恢复，包括 localSource 的真实取值', () async {
      final (controller, _) = await makeController();
      controller.applyPlaybackSnapshot(<String, Object?>{
        'document': <String, Object?>{'trackKey': 'netease:a'},
        'status': 'ready',
        'message': 'm',
        'key': 'netease:a',
        'index': 2,
        'offsetMs': 300,
        'positionMs': 1200,
        'globalOffsetMs': 250,
        'localSource': 'local',
      });
      expect(controller.document, <String, Object?>{'trackKey': 'netease:a'});
      expect(controller.status, 'ready');
      expect(controller.message, 'm');
      expect(controller.currentKey, 'netease:a');
      expect(controller.index, 2);
      expect(controller.offsetMs, 300);
      expect(controller.positionMs, 1200);
      expect(controller.globalOffsetMs, 250);
      expect(controller.localSource, 'local');
    });

    test('QJson 默认值：非字符串 source → auto，非整数 index → -1', () async {
      final (controller, _) = await makeController();
      controller.applyPlaybackSnapshot(<String, Object?>{
        'index': 1.5,
        'localSource': 1,
        'offsetMs': '300',
      });
      expect(controller.index, -1);
      expect(controller.localSource, 'auto');
      expect(controller.offsetMs, 0);
      controller.applyPlaybackSnapshot(<String, Object?>{
        'index': '2',
        'localSource': 'qq',
      });
      expect(controller.index, -1);
      expect(controller.localSource, 'qq');
    });

    test('document 是深拷贝，改入参不影响控制器', () async {
      final (controller, _) = await makeController();
      final document = <String, Object?>{'trackKey': 'x'};
      controller.applyPlaybackSnapshot(<String, Object?>{'document': document});
      document['trackKey'] = 'mutated';
      expect(controller.document['trackKey'], 'x');
    });

    test('快照往返保持偏移、来源与失败状态', () async {
      final (controller, _) = await makeController('250');
      controller.applyPlaybackSnapshot(<String, Object?>{
        'document': lyricsDoc(offsetMs: 100),
        'status': 'empty',
        'message': '加载失败',
        'key': 'netease:a',
        'index': 1,
        'offsetMs': 300,
        'positionMs': 1200,
        'globalOffsetMs': 250,
        'localSource': 'local',
      });
      final snapshot = controller.playbackSnapshot();
      final (restored, _) = await makeController();
      restored.applyPlaybackSnapshot(snapshot);
      expect(restored.document, controller.document);
      expect(restored.status, 'empty');
      expect(restored.message, '加载失败');
      expect(restored.currentKey, 'netease:a');
      expect(restored.index, 1);
      expect(restored.offsetMs, 300);
      expect(restored.positionMs, 1200);
      expect(restored.globalOffsetMs, 250);
      expect(restored.localSource, 'local');
    });

    test('恢复失败态后再次 load 会回到 idle 并清空文案', () async {
      final (restored, _) = await makeController();
      restored.applyPlaybackSnapshot(<String, Object?>{
        'status': 'empty',
        'message': '加载失败',
      });
      restored.load(track('a'));
      expect(restored.status, 'idle');
      expect(restored.message, '');
      expect(restored.currentKey, 'netease:a');
    });
  });
}
