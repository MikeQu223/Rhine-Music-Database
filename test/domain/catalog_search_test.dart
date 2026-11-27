// 分类检索（歌曲 / 专辑 / 歌单 / 歌手）的领域层测试。
//
// 被测文件：lib/domain/search/catalog_search.dart
// 规范来源：Qt/src/MusicSiren.cpp:91-190（MusicLibrary::searchSirenLocal）
//   - text = query.trimmed().toLower()；matches(v) = text.isEmpty() || v.toLower().contains(text)
//   - song → title/album/artist 任一命中；album → title/artist；playlist → 只比 title
//   - artist → 按歌手名归并后过滤歌手名（归并表由 catalog_artist.dart 提供）
//   - constexpr int pageSize = 30；
//     page = slice(results, start, 30)；hasMore = !page.isEmpty() && start+page.size() < total；
//     totals[0] = total；
//     status = page.isEmpty() ? (kind=="playlist" ? "没有匹配的本地歌单" : "没有匹配的音乐")
//                             : "找到 " + total + " 条结果"
//   最近搜索：Qt/src/MusicLibrary.cpp:107-110 读入（只收字符串、最多 12 条）、
//             :693-701 写回（removeAll → prepend → 截断 12 → 紧凑 JSON）。

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:rhine_music_database/basic/basic_models.dart';
import 'package:rhine_music_database/data/storage/preference_store.dart';
import 'package:rhine_music_database/domain/search/catalog_search.dart';

/// 测试用歌曲：只有检索相关的字段有意义，其余填稳定占位。
SirenSong _song(
  String id,
  String title,
  String artist, {
  String album = '专辑',
  String albumId = '',
  String cover = '',
}) => SirenSong(
  id: id,
  title: title,
  artist: artist,
  album: album,
  albumId: albumId,
  cover: cover,
  sourceUrl: 'https://example.test/$id.m4a',
  lyricUrl: '',
  durationMs: 0,
);

SirenAlbum _album(
  String id,
  String name,
  String artist, {
  int songCount = 0,
  List<SirenSong> songs = const <SirenSong>[],
}) => SirenAlbum(
  id: id,
  name: name,
  artist: artist,
  cover: '',
  songCount: songCount,
  songs: songs,
);

SirenCatalog _catalog({
  List<SirenSong> songs = const <SirenSong>[],
  List<SirenAlbum> albums = const <SirenAlbum>[],
}) => SirenCatalog(songs: songs, albums: albums);

/// PreferencePort 的内存实现（完全限定键，与 lib/data/storage/preference_store.dart 的契约一致）。
class _MemoryPort implements PreferencePort {
  _MemoryPort([Map<String, String>? seed]) : values = seed ?? <String, String>{};

  final Map<String, String> values;

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }

  @override
  Future<void> remove(String key) async {
    values.remove(key);
  }
}

PreferenceStore _store(_MemoryPort port) => PreferenceStore(port: port);

void main() {
  group('CatalogSearchIndex · 歌曲分类', () {
    test('空关键词匹配全部歌曲，状态串是「找到 N 条结果」', () {
      final index = CatalogSearchIndex(
        catalog: _catalog(songs: <SirenSong>[_song('s1', 'Alpha', 'Kay'), _song('s2', 'Beta', 'Zeta')]),
      );
      final SearchOutcome outcome = index.searchSongs('   ');
      expect(outcome.items, hasLength(2));
      expect(outcome.total, 2);
      expect(outcome.hasMore, isFalse);
      expect(outcome.status, '找到 2 条结果');
      expect(outcome.kind, 'song');
    });

    test('标题 / 专辑 / 艺人三处任一命中（大小写不敏感）', () {
      final index = CatalogSearchIndex(
        catalog: _catalog(
          songs: <SirenSong>[
            _song('s1', 'Kernel Overflow', 'Vanguard Sound', album: 'CONTROL'),
            _song('s2', 'Quiet Hours', 'Kay', album: 'Nightshift'),
            _song('s3', 'Other', 'Monster Siren Records', album: 'Archive'),
          ],
        ),
      );
      // 命中标题（大小写不敏感）
      expect(index.searchSongs('KERNEL').items.single['id'], 's1');
      // 命中专辑名
      expect(index.searchSongs('nightshift').items.single['id'], 's2');
      // 命中艺人名
      final SearchOutcome byArtist = index.searchSongs('siren');
      expect(byArtist.items.single['id'], 's3');
      expect(byArtist.status, '找到 1 条结果');
    });

    test('无命中：空页 + 「没有匹配的音乐」+ hasMore=false', () {
      final index = CatalogSearchIndex(
        catalog: _catalog(songs: <SirenSong>[_song('s1', 'Alpha', 'Kay')]),
      );
      final SearchOutcome outcome = index.searchSongs('nonexistent');
      expect(outcome.items, isEmpty);
      expect(outcome.total, 0);
      expect(outcome.hasMore, isFalse);
      expect(outcome.status, '没有匹配的音乐');
    });

    test('pageSize=30：首页 30 条且 hasMore，第二页接着取剩余条目', () {
      final List<SirenSong> songs = <SirenSong>[
        for (int i = 0; i < 35; i++) _song('s$i', 'Track $i', 'Kay'),
      ];
      final index = CatalogSearchIndex(catalog: _catalog(songs: songs));

      final SearchOutcome first = index.searchSongs('');
      expect(first.items, hasLength(catalogSearchPageSize));
      expect(first.total, 35);
      expect(first.hasMore, isTrue);
      expect(first.cursor, 30);
      expect(first.items.first['id'], 's0');
      expect(first.items.last['id'], 's29');

      final SearchOutcome second = index.searchSongs('', start: first.cursor);
      expect(second.items, hasLength(5));
      expect(second.items.first['id'], 's30');
      expect(second.hasMore, isFalse, reason: 'start + page.length == total');
      expect(second.total, 35, reason: 'total 是命中总数，不是本页条数');
    });

    test('起点越界返回空页但不改 total（Qt slice 的越界语义）', () {
      final index = CatalogSearchIndex(
        catalog: _catalog(songs: <SirenSong>[_song('s1', 'Alpha', 'Kay')]),
      );
      final SearchOutcome outcome = index.searchSongs('alpha', start: 5);
      expect(outcome.items, isEmpty);
      expect(outcome.total, 1, reason: 'total 仍是命中总数');
      expect(outcome.hasMore, isFalse);
      expect(outcome.status, '没有匹配的音乐');
    });
  });

  group('CatalogSearchIndex · 专辑分类', () {
    test('专辑只看名字与艺人两处，曲目名不参与', () {
      final index = CatalogSearchIndex(
        catalog: _catalog(
          albums: <SirenAlbum>[
            _album('a1', 'CONTROL', 'Vanguard Sound', songCount: 3),
            _album('a2', 'Nightshift', 'Kay', songCount: 2),
          ],
        ),
      );
      final SearchOutcome byName = index.searchAlbums('control');
      expect(byName.items.single['id'], 'a1');
      expect(byName.items.single['title'], 'CONTROL', reason: 'SirenAlbum.name → 行条目 title');
      expect(byName.items.single['trackCount'], 3);
      final SearchOutcome byArtist = index.searchAlbums('kay');
      expect(byArtist.items.single['id'], 'a2');
      // 空关键词命中全部专辑
      expect(index.searchAlbums('').total, 2);
    });
  });

  group('CatalogSearchIndex · 歌手分类', () {
    test("按 ' / ' 拆开作者并归并：同名只有一条、trackCount 累加", () {
      final index = CatalogSearchIndex(
        catalog: _catalog(
          songs: <SirenSong>[
            _song('s1', 'A', 'Kay'),
            _song('s2', 'B', 'Kay / Vanguard Sound'),
            _song('s3', 'C', 'Vanguard Sound'),
          ],
        ),
      );
      final SearchOutcome outcome = index.searchArtists('vanguard');
      expect(outcome.items, hasLength(1));
      expect(outcome.items.single['title'], 'Vanguard Sound');
      expect(outcome.items.single['trackCount'], 2);
      expect(outcome.items.single['kind'], 'artist');
      expect(outcome.total, 1);
      // 空关键词对歌手是**空列表**（catalog_artist.dart 的契约：
      // trim 后为空 → 空列表），不是「列出全部歌手」。
      expect(index.searchArtists('').items, isEmpty);
    });

    test('trackCount 降序、同数按名字升序；封面取首次命中的歌曲', () {
      final index = CatalogSearchIndex(
        catalog: _catalog(
          songs: <SirenSong>[
            _song('s1', 'A', 'Beta', cover: 'c-beta'),
            _song('s2', 'B', 'Zeta', cover: 'c-zeta'),
            _song('s3', 'C', 'Zeta', cover: 'c-zeta'),
            _song('s4', 'D', 'Alpha'),
          ],
        ),
      );
      final SearchOutcome outcome = index.searchArtists('a');
      // Beta / Alpha 都是 1 首（名字升序 Alpha, Beta），Zeta 2 首排最前。
      expect(<String>[for (final item in outcome.items) item['title']! as String], <String>[
        'Zeta',
        'Alpha',
        'Beta',
      ]);
      expect(outcome.items.first['cover'], 'c-zeta');
    });
  });

  group('CatalogSearchIndex · 歌单分类', () {
    test('只匹配歌单标题；空页状态串是「没有匹配的本地歌单」', () {
      final index = CatalogSearchIndex(
        catalog: _catalog(),
        playlists: const <BasicLocalPlaylist>[
          BasicLocalPlaylist(id: 'p1', title: '深夜播放列表', trackCount: 12),
          BasicLocalPlaylist(id: 'p2', title: 'Focus', trackCount: 3),
        ],
      );
      final SearchOutcome hit = index.searchPlaylists('深夜');
      expect(hit.items.single['id'], 'p1');
      expect(hit.items.single['title'], '深夜播放列表');
      expect(hit.items.single['trackCount'], 12);
      expect(hit.status, '找到 1 条结果');
      // 歌单不匹配艺人——条目里的 'artist' 是 provider 名（'siren'）。
      expect(index.searchPlaylists('siren').items, isEmpty);
      expect(index.searchPlaylists('siren').status, '没有匹配的本地歌单');
    });
  });

  group('CatalogSearchIndex · search 分发', () {
    final CatalogSearchIndex index = CatalogSearchIndex(
      catalog: _catalog(
        songs: <SirenSong>[_song('s1', 'Alpha', 'Kay', album: 'Nightshift')],
        albums: <SirenAlbum>[_album('a1', 'Nightshift', 'Kay', songCount: 1)],
      ),
      playlists: const <BasicLocalPlaylist>[BasicLocalPlaylist(id: 'p1', title: 'Alpha Mix')],
    );

    test('四分类各自分发到对应检索，kind 原样回填', () {
      expect(index.search(kind: 'song', query: 'alpha').items.single['kind'], 'song');
      expect(index.search(kind: 'album', query: 'night').items.single['kind'], 'album');
      expect(index.search(kind: 'artist', query: 'kay').items.single['kind'], 'artist');
      expect(index.search(kind: 'playlist', query: 'alpha').items.single['kind'], 'playlist');
    });

    test('未知分类给空页，不替调用方猜成 song', () {
      final SearchOutcome outcome = index.search(kind: 'folder', query: 'alpha');
      expect(outcome.items, isEmpty);
      expect(outcome.total, 0);
      expect(outcome.status, '没有匹配的音乐');
      expect(outcome.kind, 'folder');
    });
  });

  group('CatalogSearchHistory · 最近搜索', () {
    test('remember：新词置顶、同名去重置顶、最多 12 条', () async {
      final _MemoryPort port = _MemoryPort();
      final CatalogSearchHistory history = CatalogSearchHistory(_store(port));

      expect(await history.load(), isEmpty);
      expect(await history.remember('alpha'), <String>['alpha']);
      expect(await history.remember('beta'), <String>['beta', 'alpha']);
      expect(await history.remember('alpha'), <String>['alpha', 'beta'], reason: '同名条目先全部移除再置顶');

      for (int i = 0; i < 15; i++) {
        await history.remember('q$i');
      }
      final List<String> stored = await history.load();
      expect(stored, hasLength(catalogSearchHistoryLimit));
      expect(stored.first, 'q14', reason: '最新在前');
      expect(stored.contains('alpha'), isFalse, reason: '超出 12 条时淘汰最旧');

      // 落盘形状：Qt 用 QJsonDocument(QJsonArray::fromStringList(...)).toJson(Compact)。
      final String raw = port.values['panel/search-history']!;
      expect(jsonDecode(raw), isA<List<Object?>>());
      expect(raw.contains(' '), isFalse, reason: '紧凑 JSON，无分隔空格');
    });

    test('load：损坏值与「非字符串元素」都按下标跳过，不抛异常', () async {
      final _MemoryPort port = _MemoryPort(<String, String>{
        'panel/search-history': 'not json',
      });
      expect(await CatalogSearchHistory(_store(port)).load(), isEmpty);

      port.values['panel/search-history'] = '["alpha", 42, null, "beta"]';
      expect(await CatalogSearchHistory(_store(port)).load(), <String>['alpha', 'beta']);

      port.values['panel/search-history'] = '{"a":1}';
      expect(await CatalogSearchHistory(_store(port)).load(), isEmpty);
    });

    test('读入时最多取前 12 个字符串元素（Qt 的 size() < 12 闸门）', () async {
      final _MemoryPort port = _MemoryPort(<String, String>{
        'panel/search-history': jsonEncode(<String>[for (int i = 0; i < 20; i++) 'k$i']),
      });
      final List<String> loaded = await CatalogSearchHistory(_store(port)).load();
      expect(loaded, hasLength(12));
      expect(loaded.first, 'k0');
      expect(loaded.last, 'k11');
    });
  });
}
