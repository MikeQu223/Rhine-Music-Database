import 'package:flutter_test/flutter_test.dart';
import 'package:rhine_music_database/basic/basic_models.dart';

BasicDirectory _directory({
  required int trackCount,
  required List<String> ids,
  required int songs,
}) {
  return BasicDirectory(
    provider: 'siren',
    kind: 'playlist',
    id: 'siren-all',
    key: 'siren:playlist:all',
    title: '全部歌曲',
    artist: '塞壬唱片',
    cover: '',
    description: '塞壬唱片全部歌曲',
    trackCount: trackCount,
    songs: <SirenSong>[
      for (var index = 0; index < songs; index++)
        SirenSong(
          id: 'song-$index',
          title: '曲目 $index',
          artist: '',
          album: '',
          albumId: '',
          cover: '',
          sourceUrl: '',
          lyricUrl: '',
          durationMs: 0,
        ),
    ],
    ids: ids,
    cursor: songs,
    index: 0,
  );
}

void main() {
  group('basicLibraryTotal 镜像 MusicLibrary::libraryTotal', () {
    test('目录外就是当前列条目数', () {
      final BasicViewState state = BasicViewState(
        songs: const <SirenSong>[],
        albums: const <SirenAlbum>[],
      );
      expect(
        basicLibraryTotal(state, const <BasicListItem>[
          BasicListItem(title: 'a', kind: 'song', index: 0),
          BasicListItem(title: 'b', kind: 'song', index: 1),
          BasicListItem(title: 'c', kind: 'song', index: 2),
        ]),
        3,
      );
    });

    test('目录内取 ids / trackCount / songs 三者的最大值', () {
      // ids 比 songs 多（增量补全未跑完）时，以 ids 为准。
      final BasicViewState state = BasicViewState(
        songs: const <SirenSong>[],
        albums: const <SirenAlbum>[],
        directory: _directory(
          trackCount: 30,
          ids: <String>[for (var index = 0; index < 40; index++) 'id-$index'],
          songs: 12,
        ),
      );
      expect(basicLibraryTotal(state, basicLibraryItems(state)), 40);
    });

    test('trackCount 比 ids 与 songs 都大时以 trackCount 为准', () {
      final BasicViewState state = BasicViewState(
        songs: const <SirenSong>[],
        albums: const <SirenAlbum>[],
        directory: _directory(
          trackCount: 200,
          ids: <String>['a', 'b'],
          songs: 2,
        ),
      );
      expect(basicLibraryTotal(state, basicLibraryItems(state)), 200);
    });

    test('已落地曲目多于 ids 时以 songs 为准（Qt 同样取 max）', () {
      final BasicViewState state = BasicViewState(
        songs: const <SirenSong>[],
        albums: const <SirenAlbum>[],
        directory: _directory(
          trackCount: 0,
          ids: <String>['a'],
          songs: 5,
        ),
      );
      expect(basicLibraryTotal(state, basicLibraryItems(state)), 5);
    });
  });
}
