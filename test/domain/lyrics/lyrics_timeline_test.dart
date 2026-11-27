// DEDUP-04 歌词侧：lyrics_timeline.dart 的纯函数单测。
//
// 未执行：本任务禁止 flutter test / dart test / dart analyze，测试只按 Qt 原文逐条对照写。
// 依赖事实来自 Qt/src/LyricsController.cpp:60-64、:86-102、:117-131、:473-476、:501-509。
// 纯 Dart：不建 Widget、不启动引擎、不碰文件与网络。

import 'package:flutter_test/flutter_test.dart';
import 'package:rhine_music_database/domain/lyrics/lyrics_timeline.dart';

void main() {
  group('clampLyricsOffsetMs', () {
    test('区间内原样返回', () {
      expect(clampLyricsOffsetMs(0), 0.0);
      expect(clampLyricsOffsetMs(200), 200.0);
      expect(clampLyricsOffsetMs(-200), -200.0);
      expect(clampLyricsOffsetMs(lyricsOffsetLimitMs), 10000.0);
      expect(clampLyricsOffsetMs(-lyricsOffsetLimitMs), -10000.0);
    });

    test('超出 ±10000 夹到边界（LyricsController.cpp:63、:515）', () {
      expect(clampLyricsOffsetMs(10000.5), 10000.0);
      expect(clampLyricsOffsetMs(-10000.5), -10000.0);
      expect(clampLyricsOffsetMs(1e9), 10000.0);
      expect(clampLyricsOffsetMs(-1e9), -10000.0);
    });

    test('NaN 原样穿过（std::clamp 的比较对 NaN 恒假）', () {
      expect(clampLyricsOffsetMs(double.nan).isNaN, isTrue);
    });
  });

  group('parseLyricsOffsetPreference', () {
    test('缺失/空串/空白 → null（Qt 的 toDouble 解析失败）', () {
      expect(parseLyricsOffsetPreference(null), isNull);
      expect(parseLyricsOffsetPreference(''), isNull);
      expect(parseLyricsOffsetPreference('   '), isNull);
    });

    test('非数值文本 → null', () {
      expect(parseLyricsOffsetPreference('abc'), isNull);
      expect(parseLyricsOffsetPreference('1,5'), isNull);
      expect(parseLyricsOffsetPreference('200ms'), isNull);
      expect(parseLyricsOffsetPreference('--200'), isNull);
    });

    test('非有限值 → null（:62 的 isfinite 条件）', () {
      expect(parseLyricsOffsetPreference('NaN'), isNull);
      expect(parseLyricsOffsetPreference('Infinity'), isNull);
      expect(parseLyricsOffsetPreference('-Infinity'), isNull);
      expect(parseLyricsOffsetPreference('inf'), isNull);
      expect(parseLyricsOffsetPreference('nan'), isNull);
    });

    test('可解析值先 trim 再夹取（:61-63）', () {
      expect(parseLyricsOffsetPreference('200'), 200.0);
      expect(parseLyricsOffsetPreference(' 200 '), 200.0);
      expect(parseLyricsOffsetPreference('-200.5'), -200.5);
      expect(parseLyricsOffsetPreference('1e9'), 10000.0);
      expect(parseLyricsOffsetPreference('-1e9'), -10000.0);
    });
  });

  group('formatLyricsOffsetPreference', () {
    test('整数偏移按 QString::number 的 6 位有效数字输出（:542）', () {
      expect(formatLyricsOffsetPreference(0), '0');
      expect(formatLyricsOffsetPreference(200), '200');
      expect(formatLyricsOffsetPreference(-200), '-200');
      expect(formatLyricsOffsetPreference(10000), '10000');
      expect(formatLyricsOffsetPreference(-10000), '-10000');
      expect(formatLyricsOffsetPreference(200.0), '200');
    });

    test('非整数偏移保留 6 位有效数字并去尾零', () {
      expect(formatLyricsOffsetPreference(1234.5678), '1234.57');
      expect(formatLyricsOffsetPreference(-0.5), '-0.5');
      expect(formatLyricsOffsetPreference(0.25), '0.25');
      expect(formatLyricsOffsetPreference(999999), '999999');
    });

    test('指数分支（|value| < 1e-4 或 >= 1e6 的 %g 形态）', () {
      expect(formatLyricsOffsetPreference(0.00001), '1e-05');
      expect(formatLyricsOffsetPreference(1000000), '1e+06');
    });

    test('非有限值用 printf 的小写拼写', () {
      expect(formatLyricsOffsetPreference(double.nan), 'nan');
      expect(formatLyricsOffsetPreference(double.infinity), 'inf');
      expect(formatLyricsOffsetPreference(double.negativeInfinity), '-inf');
    });
  });

  group('QJsonValue 默认值语义', () {
    test('lyricsNumberValue 非数值 → 0', () {
      expect(lyricsNumberValue(2), 2.0);
      expect(lyricsNumberValue(2.5), 2.5);
      expect(lyricsNumberValue('2'), 0.0);
      expect(lyricsNumberValue(null), 0.0);
      expect(lyricsNumberValue(<String, Object?>{}), 0.0);
      expect(lyricsNumberValue(<Object?>[]), 0.0);
      expect(lyricsNumberValue(true), 0.0);
    });

    test('lyricsIntegerValue 只接受整数值，其余 → fallback（qjsonvalue.cpp:683-705）', () {
      expect(lyricsIntegerValue(1), 1);
      expect(lyricsIntegerValue(-2), -2);
      expect(lyricsIntegerValue(1.0), 1);
      expect(lyricsIntegerValue(1.9), 0);
      expect(lyricsIntegerValue(-1.9), 0);
      expect(lyricsIntegerValue(double.nan), 0);
      expect(lyricsIntegerValue(double.infinity), 0);
      expect(lyricsIntegerValue(double.negativeInfinity, fallback: -1), -1);
      expect(lyricsIntegerValue(2147483648), 0);
      expect(lyricsIntegerValue(-2147483649, fallback: -1), -1);
      expect(lyricsIntegerValue('1'), 0);
      expect(lyricsIntegerValue(null, fallback: -1), -1);
      expect(lyricsIntegerValue('7', fallback: -1), -1);
    });

    test('lyricsTextValue 非字符串 → fallback', () {
      expect(lyricsTextValue('line'), 'line');
      expect(lyricsTextValue(7), '');
      expect(lyricsTextValue(null, fallback: 'auto'), 'auto');
    });

    test('lyricsObjectValue 非对象 → 空对象，键归一成字符串', () {
      expect(lyricsObjectValue(null), isEmpty);
      expect(lyricsObjectValue('x'), isEmpty);
      expect(lyricsObjectValue(<Object?>[]), isEmpty);
      expect(lyricsObjectValue(<Object?, Object?>{1: 'a'}), <String, Object?>{'1': 'a'});
      final same = <String, Object?>{'a': 1};
      expect(identical(lyricsObjectValue(same), same), isTrue);
    });
  });

  group('validLyricsDocument', () {
    test('合法文档 → true（:86-102 全部条件通过）', () {
      expect(validLyricsDocument(testDocument(starts: <double>[0, 1000, 2000])), isTrue);
      expect(validLyricsDocument(testDocument()), isTrue);
      expect(
        validLyricsDocument(<String, Object?>{
          'version': 1,
          'timing': 'none',
          'plainText': '',
          'offsetMs': 0,
          'lines': <Object?>[],
        }),
        isTrue,
      );
    });

    test('version 必须恰好是整数 1（:87 + qjsonvalue.cpp:683-705）', () {
      expect(validLyricsDocument(testDocument(version: 1)), isTrue);
      expect(validLyricsDocument(testDocument(version: 1.0)), isTrue);
      expect(validLyricsDocument(testDocument(version: 2)), isFalse);
      expect(validLyricsDocument(testDocument(version: 0)), isFalse);
      expect(validLyricsDocument(testDocument(version: '1')), isFalse);
      expect(validLyricsDocument(testDocument(version: 1.5)), isFalse);
      expect(validLyricsDocument(testDocument(version: double.nan)), isFalse);
      expect(validLyricsDocument(testDocument(version: double.infinity)), isFalse);
    });

    test('timing 必须在 {line, word, none} 内（:88）', () {
      expect(validLyricsDocument(testDocument(timing: 'word')), isTrue);
      expect(validLyricsDocument(testDocument(timing: 'none')), isTrue);
      expect(validLyricsDocument(testDocument(timing: 'karaoke')), isFalse);
      expect(validLyricsDocument(testDocument(timing: '')), isFalse);
    });

    test('lines 必须是数组且不超过 5000 行（:89）', () {
      expect(validLyricsDocument(testDocument(lines: 'nope')), isFalse);
      expect(validLyricsDocument(testDocument(lines: 7)), isFalse);
      expect(
        validLyricsDocument(testDocumentWithLineCount(lyricsDocumentLineLimit)),
        isTrue,
      );
      expect(
        validLyricsDocument(testDocumentWithLineCount(lyricsDocumentLineLimit + 1)),
        isFalse,
      );
    });

    test('plainText 必须是字符串、offsetMs 必须是有限数值（:90-91）', () {
      expect(validLyricsDocument(testDocument(plainText: 1)), isFalse);
      expect(validLyricsDocument(testDocument(plainText: null)), isFalse);
      expect(validLyricsDocument(testDocument(offsetMs: '0')), isFalse);
      expect(validLyricsDocument(testDocument(offsetMs: null)), isFalse);
      expect(validLyricsDocument(testDocument(offsetMs: double.nan)), isFalse);
      expect(validLyricsDocument(testDocument(offsetMs: double.infinity)), isFalse);
    });

    test('每行 startMs 必须有限、text 必须是字符串（:94-100）', () {
      expect(validLyricsDocument(testDocumentWithLine(<String, Object?>{'startMs': 0})), isFalse);
      expect(
        validLyricsDocument(testDocumentWithLine(<String, Object?>{'text': 'a'})),
        isFalse,
      );
      expect(
        validLyricsDocument(
          testDocumentWithLine(<String, Object?>{'startMs': double.nan, 'text': 'a'}),
        ),
        isFalse,
      );
      expect(
        validLyricsDocument(
          testDocumentWithLine(<String, Object?>{'startMs': 0, 'text': 7}),
        ),
        isFalse,
      );
      expect(validLyricsDocument(testDocumentWithLine('not-a-map')), isFalse);
      expect(
        validLyricsDocument(testDocumentWithLine(<String, Object?>{'startMs': 12.5, 'text': ''})),
        isTrue,
      );
    });
  });

  group('lyricsDocumentStarts / lyricsDocumentOffsetMs', () {
    test('按文档顺序抽取 startMs，不排序（:473-476、:504）', () {
      expect(lyricsDocumentStarts(testDocument(starts: <double>[0, 1000, 2500])), <double>[0, 1000, 2500]);
      expect(lyricsDocumentStarts(testDocument(starts: <double>[500, 100])), <double>[500, 100]);
    });

    test('缺失 lines → 空列表；startMs 非数值 → 0', () {
      expect(lyricsDocumentStarts(<String, Object?>{}), isEmpty);
      expect(lyricsDocumentStarts(testDocument(lines: 'x')), isEmpty);
      expect(
        lyricsDocumentStarts(testDocumentWithLine(<String, Object?>{'text': 'a'})),
        <double>[0],
      );
    });

    test('文档级 offsetMs 缺失或非数值 → 0（:503）', () {
      expect(lyricsDocumentOffsetMs(testDocument(offsetMs: 320)), 320.0);
      expect(lyricsDocumentOffsetMs(<String, Object?>{}), 0.0);
      expect(lyricsDocumentOffsetMs(testDocument(offsetMs: '320')), 0.0);
    });
  });

  group('lyricsLineIndexAt', () {
    const starts = <double>[0, 1000, 2500];

    test('空列表 → -1', () {
      expect(lyricsLineIndexAt(const <double>[], 5000), -1);
      expect(lyricsLineIndexAt(const <double>[], 0), -1);
    });

    test('早于首行 → -1，等于首行 → 0（比较是 <=）', () {
      expect(lyricsLineIndexAt(starts, -1), -1);
      expect(lyricsLineIndexAt(starts, -0.5), -1);
      expect(lyricsLineIndexAt(starts, 0), 0);
      expect(lyricsLineIndexAt(starts, 0.001), 0);
    });

    test('行内与边界', () {
      expect(lyricsLineIndexAt(starts, 999.99), 0);
      expect(lyricsLineIndexAt(starts, 1000), 1);
      expect(lyricsLineIndexAt(starts, 2499), 1);
      expect(lyricsLineIndexAt(starts, 2500), 2);
      expect(lyricsLineIndexAt(starts, 99999), 2);
    });

    test('NaN → -1（upper_bound 比较恒假）', () {
      expect(lyricsLineIndexAt(starts, double.nan), -1);
    });
  });

  group('lyricsActiveLineIndex', () {
    test('时间轴 = position + 文档 offset + 传入 offset（:119）', () {
      final doc = testDocument(starts: <double>[1000, 2000], offsetMs: 500);
      // 时间轴：position 0 → 500，早于首行 1000。
      expect(lyricsActiveLineIndex(doc, 0), -1);
      // position 500 → 1000，命中首行。
      expect(lyricsActiveLineIndex(doc, 500), 0);
      // position 1500 → 2000，命中第二行。
      expect(lyricsActiveLineIndex(doc, 1500), 1);
      // 每曲偏移 -500 → 1500，仍停在首行。
      expect(lyricsActiveLineIndex(doc, 1500, offsetMs: -500), 0);
      // 每曲偏移 600 → 2600，越过第二行。
      expect(lyricsActiveLineIndex(doc, 1500, offsetMs: 600), 1);
    });

    test('文档缺失 offsetMs 时按 0（:119 的 toDouble 默认值）', () {
      final doc = <String, Object?>{
        'lines': <Object?>[
          <String, Object?>{'startMs': 100, 'text': 'a'},
        ],
      };
      expect(lyricsActiveLineIndex(doc, 0), -1);
      expect(lyricsActiveLineIndex(doc, 100), 0);
    });
  });

  group('copyLyricsDocument', () {
    test('深拷贝：改原文档不影响副本（QJsonObject 值语义，:471-472）', () {
      final original = testDocument(starts: <double>[0, 1000]);
      final copy = copyLyricsDocument(original);
      (original['lines'] as List<Object?>).add(<String, Object?>{'startMs': 9, 'text': 'z'});
      original['offsetMs'] = 777;
      expect(copy['offsetMs'], 0);
      expect((copy['lines'] as List<Object?>).length, 2);
      expect(identical(copy['lines'], original['lines']), isFalse);
    });

    test('叶子按值保留', () {
      final copy = copyLyricsDocument(<String, Object?>{
        'a': 1,
        'b': 'x',
        'c': null,
        'd': <Object?>[1, 'y', <String, Object?>{'e': 2}],
      });
      expect(copy['a'], 1);
      expect(copy['b'], 'x');
      expect(copy['c'], isNull);
      expect((copy['d'] as List<Object?>)[2], <String, Object?>{'e': 2});
    });
  });
}

Map<String, Object?> testDocument({
  Object? version = 1,
  Object? timing = 'line',
  Object? plainText = '',
  Object? offsetMs = 0,
  List<double> starts = const <double>[],
  Object? lines,
}) {
  return <String, Object?>{
    'version': version,
    'timing': timing,
    'plainText': plainText,
    'offsetMs': offsetMs,
    'lines': lines ??
        <Object?>[
          for (var i = 0; i < starts.length; i += 1)
            <String, Object?>{'startMs': starts[i], 'text': 'line$i'},
        ],
  };
}

Map<String, Object?> testDocumentWithLine(Object? line) {
  return <String, Object?>{
    'version': 1,
    'timing': 'line',
    'plainText': '',
    'offsetMs': 0,
    'lines': <Object?>[line],
  };
}

Map<String, Object?> testDocumentWithLineCount(int count) {
  return <String, Object?>{
    'version': 1,
    'timing': 'line',
    'plainText': '',
    'offsetMs': 0,
    'lines': <Object?>[
      for (var i = 0; i < count; i += 1)
        <String, Object?>{'startMs': i.toDouble(), 'text': 'l$i'},
    ],
  };
}