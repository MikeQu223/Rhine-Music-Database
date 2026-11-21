import 'package:flutter_test/flutter_test.dart';
import 'package:rhine_music_database/basic/basic_models.dart';

void main() {
  test('插件歌词文档：lines 与 translation 原样搬运并按 startMs 排序', () {
    final BasicLyricsDocument doc = basicLyricsFromDocument(<String, Object?>{
      'version': 1,
      'source': 'netease',
      'timing': 'line',
      'offsetMs': 0,
      'plainText': 'hello',
      'lines': <Object?>[
        <String, Object?>{'startMs': 5000.0, 'text': '第二句', 'translation': 'second'},
        <String, Object?>{'startMs': 1000.0, 'text': '第一句', 'translation': 'first'},
      ],
    });
    expect(doc.timed, isTrue);
    expect(doc.lines.map((BasicLyricLine l) => l.text), <String>['第一句', '第二句']);
    expect(doc.lines.map((BasicLyricLine l) => l.translation), <String>['first', 'second']);
    expect(doc.plainText, 'hello');
  });

  test('插件歌词文档：非法/空值退回空文档而不是抛异常', () {
    expect(basicLyricsFromDocument(null).isEmpty, isTrue);
    expect(basicLyricsFromDocument(<String, Object?>{}).isEmpty, isTrue);
    final BasicLyricsDocument doc = basicLyricsFromDocument(<String, Object?>{
      'lines': <Object?>[
        <String, Object?>{'startMs': 0, 'text': ''},
      ],
    });
    expect(doc.isEmpty, isTrue);
    expect(doc.timed, isFalse);
  });

  test('插件歌词文档：translation 缺失时为空串，转域文档仍带这个键', () {
    final BasicLyricsDocument doc = basicLyricsFromDocument(<String, Object?>{
      'lines': <Object?>[
        <String, Object?>{'startMs': 1000, 'text': '只有原文'},
      ],
    });
    expect(doc.lines.single.translation, '');
    final Map<String, Object?> json = doc.toLyricsDocument(source: 'netease');
    expect(json['timing'], 'line');
    final List<Object?> lines = json['lines']! as List<Object?>;
    expect((lines.single as Map<String, Object?>)['translation'], '');
  });
}
