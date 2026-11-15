/// 资料库**五列**的列表真值 + 高亮身份映射测试
/// （Qt/src/MusicLibrary.cpp:195-207 sourceItems(lane) / :225-231 libraryIndex()；
///   Qt/src/MusicDirectory.cpp:302-319 selectDirectory）。
///
/// 覆盖用户可见的错位：
///  - 列是资料库的列（搜索结果/喜欢的歌曲/我的歌单/全部歌曲/全部专辑），不是 provider：
///    单个 Siren 平台也有五列，←/→ 换的是列，根页列表只承载 selectedLane 那一列；
///  - 搜索结果列里专辑行与曲目行同列混排时，state.songs 的下标不是 items 的行号
///    （专辑行占前段），身份只能按 id 认；
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
  int parentLane = basicDefaultLane,
  BasicSelection? parentSelection,
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
    parentLane: parentLane,
    parentSelection: parentSelection,
  );
}

void main() {
  group('列序（Qt MusicLibrary::sourceOrder / columns）', () {
    test('五列逐字等于 Qt 构造里的 columns（MusicLibrary.cpp:26-27）', () {
      expect(basicSirenColumns, <String>[
        '搜索结果',
        '喜欢的歌曲',
        '我的歌单',
        '全部歌曲',
        '全部专辑',
      ]);
    });

    test('Siren 的 sourceOrder 是 {1,2,3,4,0}（不是 kugou 的四列 {1,2,3,0}）', () {
      expect(basicSirenSourceOrder, <int>[1, 2, 3, 4, 0]);
      expect(basicSourceOrderIndex(1), 0);
      expect(basicSourceOrderIndex(2), 1);
      expect(basicSourceOrderIndex(3), 2);
      expect(basicSourceOrderIndex(4), 3);
      expect(basicSourceOrderIndex(0), 4);
    });

    test('←/→ 每步一个列位并回环（wrap(index ± 1, sources.size())）', () {
      var lane = basicDefaultLane; // 3（全部歌曲）
      final List<int> forward = <int>[lane];
      for (var step = 0; step < 5; step++) {
        lane = basicStepSourceLane(lane, 1);
        forward.add(lane);
      }
      expect(forward, <int>[3, 4, 0, 1, 2, 3], reason: '→ 依次 4,0,1,2,3');

      final List<int> backward = <int>[lane];
      for (var step = 0; step < 5; step++) {
        lane = basicStepSourceLane(lane, -1);
        backward.add(lane);
      }
      expect(backward, <int>[3, 2, 1, 0, 4, 3], reason: '← 依次 2,1,0,4,3');
    });

    test('越界列不崩：名字回空串、空态文案各自不同', () {
      expect(basicLaneName(-1), '');
      expect(basicLaneName(basicSirenColumns.length), '');
      expect(basicLaneName(3), '全部歌曲');

      final Set<String> notices = <String>{
        for (var lane = 0; lane < basicSirenColumns.length; lane++)
          basicLaneEmptyNotice(lane),
      };
      expect(notices.length, basicSirenColumns.length, reason: '每列空态各说各话');
      expect(basicLaneEmptyNotice(1), contains('账号'));
      expect(basicLaneEmptyNotice(2), contains('账号'));
      expect(basicLaneEmptyNotice(3), contains('曲库'));
    });
  });

  group('basicLibraryItems（列表真值，按列投影）', () {
    test('全部歌曲列（lane 3）：只列曲目行，index 指回 state.songs', () {
      final SirenSong s1 = _song('s1', '第一首');
      final SirenSong s2 = _song('s2', '第二首');
      final SirenAlbum a1 = _album('album-1', '测试专辑', <SirenSong>[s1, s2]);
      final BasicViewState state = BasicViewState(
        phase: BasicPhase.library,
        selectedLane: 3,
        songs: <SirenSong>[s1, s2],
        albums: <SirenAlbum>[a1],
      );

      final List<BasicListItem> items = basicLibraryItems(state);

      expect(
        items.map((BasicListItem item) => item.kind).toList(),
        <String>['song', 'song'],
        reason: '专辑在 lane 4，不属于全部歌曲列',
      );
      expect(items.map((BasicListItem item) => item.index).toList(), <int>[0, 1]);
      expect(items.map((BasicListItem item) => item.id).toList(), <String>['s1', 's2']);
      expect(items.first.title, '第一首');
    });

    test('全部专辑列（lane 4）：只列专辑行，kind=album、index 指回 state.albums', () {
      final SirenAlbum a1 = _album('album-1', '专辑一', <SirenSong>[_song('s1', '第一首')]);
      final SirenAlbum a2 = _album('album-2', '专辑二', <SirenSong>[_song('s2', '第二首')]);
      final BasicViewState state = BasicViewState(
        phase: BasicPhase.library,
        selectedLane: 4,
        songs: <SirenSong>[_song('s1', '第一首'), _song('s2', '第二首')],
        albums: <SirenAlbum>[a1, a2],
      );

      final List<BasicListItem> items = basicLibraryItems(state);

      expect(items.map((BasicListItem item) => item.kind).toList(), <String>['album', 'album']);
      expect(items.map((BasicListItem item) => item.index).toList(), <int>[0, 1]);
      expect(items.map((BasicListItem item) => item.id).toList(),
          <String>['album-1', 'album-2']);
      expect(items[1].title, '专辑二');
    });

    test('搜索结果列（lane 0）：命中专辑行 + 曲目行同列，index 指回各自的过滤后表', () {
      final SirenSong s2 = _song('s2', '第二首');
      final SirenAlbum a1 = _album('album-1', '测试专辑', <SirenSong>[_song('s1', '第一首'), s2]);
      final BasicViewState state = BasicViewState(
        phase: BasicPhase.library,
        selectedLane: basicSearchLane,
        query: '第二',
        // controller 把**过滤后**的集合投进 state（Qt lists[0]），models 不再二次过滤。
        songs: <SirenSong>[s2],
        albums: <SirenAlbum>[a1],
      );

      final List<BasicListItem> items = basicLibraryItems(state);

      expect(items.map((BasicListItem item) => item.kind).toList(),
          <String>['album', 'song']);
      expect(items.map((BasicListItem item) => item.index).toList(), <int>[0, 0]);
      expect(items.map((BasicListItem item) => item.id).toList(),
          <String>['album-1', 's2']);
      expect(items[1].title, '第二首');
    });

    test('搜索结果列空关键词 = 该列清空（Qt 清 lists[0] 只留提示文案）', () {
      final BasicViewState state = BasicViewState(
        phase: BasicPhase.library,
        selectedLane: basicSearchLane,
        query: '   ',
        songs: <SirenSong>[_song('s1', '第一首')],
        albums: <SirenAlbum>[_album('album-1', '测试专辑', <SirenSong>[_song('s1', '第一首')])],
      );

      expect(basicLibraryItems(state), isEmpty);
    });

    test('账号列（lane 1/2）：诚实空，不编条目', () {
      final BasicViewState base = BasicViewState(
        phase: BasicPhase.library,
        songs: <SirenSong>[_song('s1', '第一首')],
        albums: <SirenAlbum>[_album('album-1', '测试专辑', <SirenSong>[_song('s1', '第一首')])],
      );

      expect(basicLibraryItems(base.copyWith(selectedLane: 1)), isEmpty);
      expect(basicLibraryItems(base.copyWith(selectedLane: 2)), isEmpty);
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
      expect(items[1].id, 's2');
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
    test('搜索结果列混排：按 id 找到自己的行，不吃专辑偏移', () {
      final SirenSong s1 = _song('s1', '第一首');
      final SirenSong s2 = _song('s2', '第二首');
      final SirenAlbum a1 = _album('album-1', '测试专辑', <SirenSong>[s1, s2]);
      final BasicViewState state = BasicViewState(
        phase: BasicPhase.library,
        selectedLane: basicSearchLane,
        query: '第',
        songs: <SirenSong>[s1, s2],
        albums: <SirenAlbum>[a1],
        song: s2,
      );

      final List<BasicListItem> items = basicLibraryItems(state);

      // 行序：[专辑, 第一首, 第二首]；state.songs 下标 1 落在"第一首"行上。
      expect(basicSelectedItemIndex(state, items), 2);
      expect(items[basicSelectedItemIndex(state, items)].title, '第二首');
      expect(items[1].title, '第一首');
    });

    test('两个专辑 + 曲目：偏移随专辑行数变化，不写死', () {
      final SirenSong s1 = _song('s1', '第一首');
      final SirenSong s2 = _song('s2', '第二首');
      final BasicViewState state = BasicViewState(
        phase: BasicPhase.library,
        selectedLane: basicSearchLane,
        query: '第',
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
        selectedLane: 3,
        songs: <SirenSong>[s1, s2],
        song: s2,
      );

      final List<BasicListItem> items = basicLibraryItems(state);

      expect(basicSelectedItemIndex(state, items), 1);
      expect(items[1].index, 1);
    });

    test('条目自带 id 是身份真值：源下标不可信时仍能对上', () {
      final BasicViewState state = BasicViewState(
        phase: BasicPhase.library,
        selectedLane: 3,
        songs: <SirenSong>[_song('s1', '第一首'), _song('s2', '第二首')],
        selection: const BasicSelection(kind: 'song', id: 's2'),
      );
      const List<BasicListItem> items = <BasicListItem>[
        BasicListItem(title: '幽灵行', kind: 'song', index: 99, id: 's9'),
        BasicListItem(title: '第二首', kind: 'song', index: 1, id: 's2'),
      ];

      expect(basicSelectedItemIndex(state, items), 1);
    });

    test('专辑身份：在专辑列里匹配自己的行', () {
      final SirenAlbum a1 = _album('album-1', '专辑一', <SirenSong>[_song('s1', '第一首')]);
      final SirenAlbum a2 = _album('album-2', '专辑二', <SirenSong>[_song('s2', '第二首')]);
      final BasicViewState state = BasicViewState(
        phase: BasicPhase.library,
        selectedLane: 4,
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
        selectedLane: 3,
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
        selectedLane: 3,
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
    test('资料库根：当前列名（columns.value(selectedLane)）', () {
      expect(basicLibraryTitle(const BasicViewState()), '全部歌曲');
      expect(
        basicLibraryTitle(const BasicViewState(selectedLane: basicSearchLane)),
        '搜索结果',
      );
      expect(basicLibraryTitle(const BasicViewState(selectedLane: 4)), '全部专辑');
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

    test('列号越界：列名取不到时回落 provider 名（不显示空标题）', () {
      expect(basicLibraryTitle(const BasicViewState(selectedLane: -1)), basicLibraryName);
      expect(
        basicLibraryTitle(
          const BasicViewState(selectedLane: basicSirenColumns.length),
        ),
        basicLibraryName,
      );
    });
  });
}
