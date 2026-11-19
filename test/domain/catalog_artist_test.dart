// 音乐人归并检索的领域层测试。
//
// 被测文件：lib/domain/search/catalog_artist.dart
// 规范来源：Qt/src/MusicSiren.cpp:91-190（searchSirenLocal 的 artist 分支）
//   - 按 artists[].name 归并，每首计一次 trackCount，name 为空跳过；
//   - 过滤：query.trimmed().toLower().contains(...)，空 query 恒真；
//   - 排序：trackCount 降序，相同再按 title(name) 升序。

import 'package:flutter_test/flutter_test.dart';
import 'package:rhine_music_database/domain/search/catalog_artist.dart';

Map<String, Object?> _song(
  String id,
  String title,
  String album,
  Object artist,
) =>
    <String, Object?>{
      'id': id,
      'title': title,
      'album': album,
      'artist': artist,
    };

void main() {
  group('CatalogArtistIndex.search', () {
    test('单串作者命中：子串大小写不敏感', () {
      final index = CatalogArtistIndex(<Map<String, Object?>>[
        _song('s1', 'A', 'al', 'Vanguard Sound'),
        _song('s2', 'B', 'al', 'Monster Siren Records'),
      ]);
      final hits = index.search('siren');
      expect(hits, hasLength(1));
      expect(hits.single.name, 'Monster Siren Records');
      expect(hits.single.id, 'artist:Monster Siren Records');
      expect(hits.single.trackCount, 1);
    });

    test('List<String> 作者拆分：每个作者各计一次', () {
      final index = CatalogArtistIndex(<Map<String, Object?>>[
        _song('s1', 'A', 'al', <String>['Kay', 'Vanguard Sound']),
        _song('s2', 'B', 'al', <String>['Kay']),
        _song('s3', 'C', 'al', 'Vanguard Sound'),
      ]);
      final byName = <String, CatalogArtist>{
        for (final artist in index.search('a')) artist.name: artist,
      };
      expect(byName.keys.toSet(), <String>{'Kay', 'Vanguard Sound'});
      expect(byName['Kay']!.trackCount, 2);
      expect(byName['Vanguard Sound']!.trackCount, 2);
      expect(byName['Kay']!.id, 'artist:Kay');
    });

    test('trackCount 累加并按降序排序，同数按 name 升序', () {
      final index = CatalogArtistIndex(<Map<String, Object?>>[
        _song('s1', 'A', 'al', 'Zeta'),
        _song('s2', 'B', 'al', 'Zeta'),
        _song('s3', 'C', 'al', 'Zeta'),
        _song('s4', 'D', 'al', <String>['Beta', 'Alpha']),
        _song('s5', 'E', 'al', 'Alpha'),
        _song('s6', 'F', 'al', 'Beta'),
        _song('s7', 'G', 'al', 'Gamma'),
      ]);
      final all = index.search('a');
      expect(
        all.map((artist) => artist.name).toList(),
        <String>['Zeta', 'Alpha', 'Beta', 'Gamma'],
      );
      expect(
        all.map((artist) => artist.trackCount).toList(),
        <int>[3, 2, 2, 1],
      );
    });

    test('大小写不敏感：查询与数据两种大小写互相匹配', () {
      final index = CatalogArtistIndex(<Map<String, Object?>>[
        _song('s1', 'A', 'al', 'VANGUARD SOUND'),
      ]);
      expect(index.search('vanguard'), hasLength(1));
      expect(index.search('Vanguard'), hasLength(1));
      expect(index.search('SOUND'), hasLength(1));
      expect(index.search('siren'), isEmpty);
    });

    test('空查询返回空列表', () {
      final index = CatalogArtistIndex(<Map<String, Object?>>[
        _song('s1', 'A', 'al', 'Kay'),
      ]);
      expect(index.search(''), isEmpty);
      expect(index.search('   '), isEmpty);
    });
  });

  test('CatalogArtist 是 const 构造且 toString 可读', () {
    const artist = CatalogArtist('artist:Kay', 'Kay', 3);
    expect(artist.id, 'artist:Kay');
    expect(artist.name, 'Kay');
    expect(artist.trackCount, 3);
    expect(artist.toString(), contains('artist:Kay'));
    expect(artist.toString(), contains('trackCount: 3'));
  });
}
