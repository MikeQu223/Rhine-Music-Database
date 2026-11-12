/// 资料库列表与高亮的身份映射测试（Qt/src/MusicLibrary.cpp:196-230 libraryItems/
/// libraryIndex；Qt/src/MusicDirectory.cpp:302-319 selectDirectory）。
///
/// 覆盖三处用户可见的错位：
///  - 资料库首屏专辑行 + 曲目混排时，state.songs 的下标不是 items 的行号（专辑行占前段）；
///  - 同名曲目不能用标题匹配，只能按 id；
///  - 目录内高亮是位置真值 directory.index，而不是当前曲目的身份。
///
/// 本文件只编写、不执行：禁令下禁 dart test / flutter test / analyze / format / pub get。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:rhine_music_database/basic/basic_hud.dart';
import 'package:rhine_music_database/basic/basic_models.dart';

SirenSong _song(String id, String title, {String albumId = 'album-1'}) {
  return SirenSong(
    id: id,
    title: title,
    artist: '塞壬唱片',
    album: albumId,
    albumId: albumId,
    cover: '',
    sourceUrl: 'https://example.invalid/$id.mp3',
    lyricUrl: '',
    durationMs: 180000,
  );
}

SirenAlbum _album(String id, String name, List<SirenSong> songs) {
  return SirenAlbum(
    id: id,
    name: name,
    artist: '塞壬唱片',
    cover: '',
    songCount: songs.length,
    songs: songs,
  );
}

/// Qt MusicSiren.cpp:205-218 的目录 item（只保留基本版投影的字段）。
BasicDirectory _directory({
  required List<SirenSong> songs,
  int index = 0,
  BasicDirectory? parent,
}) {
  return BasicDirectory(
    provider: sirenProvider,
    kind: 'playlist',
    id: 'siren-all',
    key: 'siren:playlist:all',
    title: '全部歌曲',
    artist: '塞壬唱片',
    cover: '',
    description: '塞壬唱片全部歌曲',
    trackCount: songs.length,
    virtual: true,
    songs: songs,
    ids: <String>[for (final SirenSong song in songs) song.id],
    cursor: songs.length,
    index: index,
    parent: parent,
  );
}

void main() {
  group('basicLibraryItems（列表真值）', () {
    test('资料库首屏：专辑行在前、曲目行在后，index 指回各自的源', () {
      final SirenSong s1 = _song('s1', '第一首');
      final SirenSong s2 = _song('s2', '第二首');
      final SirenAlbum a1 = _album('album-1', '测试专辑', <SirenSong>[s1, s2]);
      final BasicViewState state = BasicViewState(
        phase: BasicPhase.library,
        songs: <SirenSong>[s1, s2],
        albums: <SirenAlbum>[a1],
      );

      final List<BasicListItem> items = basicLibraryItems(state);

      expect(
        items.map((BasicListItem item) => item.kind).toList(),
        <String>['album', 'song', 'song'],
      );
      expect(
        items.map((BasicListItem item) => item.index).toList(),
        <int>[0, 0, 1],
      );
      expect(items.first.title, '测试专辑');
      expect(items[1].title, '第一首');
      expect(items[2].title, '第二首');
    });

    test('目录打开：只列目录曲目，专辑行不再出现', () {
      final List<SirenSong> songs = <SirenSong>[
        _song('s1', '第一首'),
        _song('s2', '第二首'),
      ];
      final BasicViewState state = BasicViewState(
        phase: BasicPhase.library,
        songs: songs,
        albums: <SirenAlbum>[_album('album-1', '测试专辑', songs)],
        directory: _directory(songs: songs),
      );

      final List<BasicListItem> items = basicLibraryItems(state);

      expect(items.length, 2);
      expect(items.every((BasicListItem item) => item.kind == 'song'), isTrue);
      expect(items[1].index, 1);
      expect(items[1].title, '第二首');
    });

    test('专辑详情：行只含该专辑曲目，index 是该专辑 songs 的下标', () {
      final List<SirenSong> songs = <SirenSong>[
        _song('s1', '第一首'),
        _song('s2', '第二首'),
      ];
      final SirenAlbum album = _album('album-1', '测试专辑', songs);
      final BasicViewState state = BasicViewState(
        phase: BasicPhase.detail,
        songs: songs,
        album: album,
        song: songs[1],
      );

      final List<BasicListItem> items = basicLibraryItems(state);

      expect(items.length, 2);
      expect(
        items.map((BasicListItem item) => item.title).toList(),
        <String>['第一首', '第二首'],
      );
      expect(basicSelectedItemIndex(state, items), 1);
    });
  });

  group('basicSelectedItemIndex（身份 → 行号）', () {
    test('专辑 + 曲目混排：按 id 找到自己的行，不吃专辑偏移', () {
      final SirenSong s1 = _song('s1', '第一首');
      final SirenSong s2 = _song('s2', '第二首');
      final SirenAlbum a1 = _album('album-1', '测试专辑', <SirenSong>[s1, s2]);
      final BasicViewState state = BasicViewState(
        phase: BasicPhase.library,
        songs: <SirenSong>[s1, s2],
        albums: <SirenAlbum>[a1],
        song: s2,
      );

      final List<BasicListItem> items = basicLibraryItems(state);

      // 行序：[专辑, 第一首, 第二首]；state.songs 下标 1 落在"第一首"行上（旧实现的错位）。
      expect(basicSelectedItemIndex(state, items), 2);
      expect(items[basicSelectedItemIndex(state, items)].title, '第二首');
      expect(items[1].title, '第一首');
    });

    test('两个专辑 + 曲目：偏移随专辑行数变化，不写死', () {
      final SirenSong s1 = _song('s1', '第一首');
      final SirenSong s2 = _song('s2', '第二首');
      final BasicViewState state = BasicViewState(
        phase: BasicPhase.library,
        songs: <SirenSong>[s1, s2],
        albums: <SirenAlbum>[
          _album('album-1', '专辑一', <SirenSong>[s1]),
          _album('album-2', '专辑二', <SirenSong>[s2]),
        ],
        song: s2,
      );

      final List<BasicListItem> items = basicLibraryItems(state);

      expect(items.length, 4);
      expect(basicSelectedItemIndex(state, items), 3);
      expect(items[3].title, '第二首');
    });

    test('同名曲目：只按 id 匹配，不按标题', () {
      final SirenSong s1 = _song('s1', '同名');
      final SirenSong s2 = _song('s2', '同名');
      final BasicViewState state = BasicViewState(
        phase: BasicPhase.library,
        songs: <SirenSong>[s1, s2],
        song: s2,
      );

      final List<BasicListItem> items = basicLibraryItems(state);

      expect(basicSelectedItemIndex(state, items), 1);
      expect(items[1].index, 1);
    });

    test('过滤后：行号取过滤列表里的位置', () {
      final SirenSong s1 = _song('s1', '第一首');
      final SirenSong s2 = _song('s2', '第二首');
      final SirenAlbum a1 = _album('album-1', '测试专辑', <SirenSong>[s1, s2]);
      final BasicViewState state = BasicViewState(
        phase: BasicPhase.library,
        query: '第二',
        songs: <SirenSong>[s2],
        albums: <SirenAlbum>[a1],
        song: s2,
      );

      final List<BasicListItem> items = basicLibraryItems(state);

      expect(items.length, 2);
      expect(basicSelectedItemIndex(state, items), 1);
      expect(items[1].title, '第二首');
    });

    test('过滤后没有专辑行：从 0 起算', () {
      final SirenSong s2 = _song('s2', '第二首');
      final BasicViewState state = BasicViewState(
        phase: BasicPhase.library,
        query: '第二',
        songs: <SirenSong>[s2],
        song: s2,
      );

      expect(basicSelectedItemIndex(state, basicLibraryItems(state)), 0);
    });

    test('专辑身份：当前专辑在专辑行里匹配自己的行', () {
      final SirenAlbum a1 = _album('album-1', '专辑一', <SirenSong>[_song('s1', '第一首')]);
      final SirenAlbum a2 = _album('album-2', '专辑二', <SirenSong>[_song('s2', '第二首')]);
      final BasicViewState state = BasicViewState(
        phase: BasicPhase.library,
        songs: const <SirenSong>[],
        albums: <SirenAlbum>[a2, a1],
        album: a1,
      );

      final List<BasicListItem> items = basicLibraryItems(state);

      expect(
        items.map((BasicListItem item) => item.kind).toList(),
        <String>['album', 'album'],
      );
      expect(basicSelectedItemIndex(state, items), 1);
      expect(items[1].title, '专辑一');
    });

    test('目录内：位置真值 directory.index 优先于当前曲目身份', () {
      final List<SirenSong> songs = <SirenSong>[
        _song('s1', '第一首'),
        _song('s2', '第二首'),
        _song('s3', '第三首'),
      ];
      final BasicViewState state = BasicViewState(
        phase: BasicPhase.library,
        songs: songs,
        directory: _directory(songs: songs, index: 2),
        song: songs.first,
      );

      final List<BasicListItem> items = basicLibraryItems(state);

      expect(basicSelectedItemIndex(state, items), 2);
      expect(items[2].title, '第三首');
    });

    test('目录 index 越界时回落到 0，不越界读列表', () {
      final List<SirenSong> songs = <SirenSong>[_song('s1', '第一首')];
      final BasicViewState state = BasicViewState(
        phase: BasicPhase.library,
        songs: songs,
        directory: _directory(songs: songs, index: 7),
      );

      expect(basicSelectedItemIndex(state, basicLibraryItems(state)), 0);
    });

    test('空列表 / 无当前曲目 → 0', () {
      expect(
        basicSelectedItemIndex(const BasicViewState(), const <BasicListItem>[]),
        0,
      );
      final BasicViewState state = BasicViewState(
        phase: BasicPhase.library,
        songs: <SirenSong>[_song('s1', '第一首')],
      );
      expect(
        basicSelectedItemIndex(state, basicLibraryItems(state)),
        0,
      );
    });

    test('行 index 越界时回落 0，不越界读源列表', () {
      final BasicViewState state = BasicViewState(
        phase: BasicPhase.library,
        songs: <SirenSong>[_song('s1', '第一首')],
        song: _song('s1', '第一首'),
      );
      const List<BasicListItem> items = <BasicListItem>[
        BasicListItem(title: '幽灵行', kind: 'song', index: 9),
      ];

      expect(basicSelectedItemIndex(state, items), 0);
    });
  });

  group('basicLibraryTitle（Qt MusicLibrary::libraryName）', () {
    test('资料库根：provider 名', () {
      expect(basicLibraryTitle(const BasicViewState()), basicLibraryName);
    });

    test('目录内：目录标题', () {
      final List<SirenSong> songs = <SirenSong>[_song('s1', '第一首')];
      final BasicViewState state = BasicViewState(
        phase: BasicPhase.library,
        songs: songs,
        directory: _directory(songs: songs),
      );

      expect(basicLibraryTitle(state), '全部歌曲');
    });

    test('目录标题为空：回落 provider 名', () {
      final List<SirenSong> songs = <SirenSong>[_song('s1', '第一首')];
      final BasicDirectory empty = BasicDirectory(
        provider: sirenProvider,
        kind: 'playlist',
        id: 'siren-all',
        key: 'siren:playlist:all',
        title: '',
        artist: '塞壬唱片',
        cover: '',
        description: '',
        trackCount: songs.length,
        songs: songs,
        ids: const <String>['s1'],
        cursor: 1,
        index: 0,
      );

      expect(
        basicLibraryTitle(
          BasicViewState(phase: BasicPhase.library, songs: songs, directory: empty),
        ),
        basicLibraryName,
      );
    });
  });
}
