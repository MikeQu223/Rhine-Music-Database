import 'package:flutter_test/flutter_test.dart';
import 'package:rhine_music_database/basic/basic_models.dart';

void main() {
  group('basicCleanArtist', () {
    test('去掉段首尾的顿号与零宽字符', () {
      expect(basicCleanArtist('洛天依 / 阑阗 / 、薛钦'), '洛天依 / 阑阗 / 薛钦');
      expect(basicCleanArtist('\u200b洛天依 / 阑阗 / \u200b、薛钦'), '洛天依 / 阑阗 / 薛钦');
      expect(basicCleanArtist('洛天依 / 阑阗 / 薛钦、'), '洛天依 / 阑阗 / 薛钦');
    });

    test('空段与纯标点段不产出空名字', () {
      expect(basicCleanArtist(' / '), '');
      expect(basicCleanArtist('洛天依 / '), '洛天依');
      expect(basicCleanArtist(''), '');
    });

    test('没有分隔符时原样返回', () {
      expect(basicCleanArtist('HOYO-MiX'), 'HOYO-MiX');
      expect(basicCleanArtist('  HOYO-MiX  '), 'HOYO-MiX');
    });
  });
}
