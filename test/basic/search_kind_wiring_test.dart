import 'package:flutter_test/flutter_test.dart';
import 'package:rhine_music_database/basic/basic_models.dart';
import 'package:rhine_music_database/domain/search/catalog_search.dart';

void main() {
  group('分类检索的 tab / 分组动作词表', () {
    test('四分类顺序与索引一致（Qt order = {0,3,1,2}）', () {
      expect(catalogSearchKinds, <String>['song', 'album', 'playlist', 'artist']);
      expect(catalogSearchKinds.length, 4);
    });

    test('索引按分类分派：专辑分类不返回曲目行', () {
      final SirenSong song = const SirenSong(
        id: '1',
        title: '星',
        artist: '塞壬唱片-MSR',
        album: '回声',
        albumId: 'a1',
        cover: '',
        sourceUrl: '',
        lyricUrl: '',
        durationMs: 1000,
      );
      final SirenAlbum album = SirenAlbum(
        id: 'a1',
        name: '回声',
        artist: '塞壬唱片-MSR',
        cover: '',
        songCount: 1,
        songs: <SirenSong>[song],
      );
      final CatalogSearchIndex index = CatalogSearchIndex(
        catalog: SirenCatalog(songs: <SirenSong>[song], albums: <SirenAlbum>[album]),
      );
      expect(index.search(kind: 'album', query: '').items.single['kind'], 'album');
      expect(index.search(kind: 'song', query: '').items.single['kind'], 'song');
      expect(index.search(kind: 'artist', query: '塞壬').total, 1);
      expect(index.search(kind: 'playlist', query: '').status, '没有匹配的本地歌单');
    });

    test('分组键只认 none/artist/album，空关键词状态串是 Qt 原文', () {
      final CatalogSearchIndex index = CatalogSearchIndex(
        catalog: const SirenCatalog(songs: <SirenSong>[], albums: <SirenAlbum>[]),
      );
      final SearchOutcome outcome = index.search(kind: 'song', query: '星');
      expect(outcome.status, '没有匹配的音乐');
    });
  });
}
