// 分类检索（歌曲 / 专辑 / 歌单 / 歌手）的纯领域层实现。
//
// 规范来源：Qt/src/MusicSiren.cpp:91-190 `MusicLibrary::searchSirenLocal`——
// 塞壬曲库是内存过滤，没有网络，因此「分类检索」的语义完全由这一段决定：
//
//   text    = query.trimmed().toLower();
//   matches(v) = text.isEmpty() || v.toLower().contains(text);
//   song    → title / album / artist 任一命中
//   album   → title / artist 任一命中
//   artist  → 由歌曲的 artists[] 按**歌手名**归并出条目（同名合并、trackCount 计数），
//             再对歌手名做 matches()，最后 trackCount 降序 / title 升序排序
//   playlist→ 只对歌单标题匹配
//
//   constexpr int pageSize = 30;
//   page   = MusicData::slice(results, start, pageSize);
//   lists[0]  = more ? MusicData::unique(lists[0], page) : page
//   searchCursor = start + page.size()
//   hasMore[0]   = !page.isEmpty() && start + page.size() < total
//   totals[0]    = total
//   status = page.isEmpty()
//              ? (kind == "playlist" ? "没有匹配的本地歌单" : "没有匹配的音乐")
//              : "找到 " + total + " 条结果"
//
// 最近搜索白名单：Qt/src/MusicLibrary.cpp:107-110 读入（只收字符串、最多 12 条）、
// :693-701 写回（removeAll → prepend → 截断 12 → QJsonDocument(...).toJson(Compact)），
// 键名 "search-history"（Qt/src/Host.cpp 面板白名单，落盘前缀 "panel/"）。
//
// 本文件是纯 Dart（不 import flutter），也只依赖同为纯 Dart 的
// basic_models / preference_store / catalog_artist：UI 与测试共用一套语义。
//
// 与 Qt 的唯一已知差异（不掩饰）：塞壬曲库的歌曲负载里没有 Qt 那份上游生成的
// `artist.id`（siren.mjs:28-30 的 'a' + sha1(name)[0:16]），因此歌手条目的 id
// 用归并键（歌手名）本身，key 固定 `siren:artist:<name>`。Qt 的归并键与排序键
// 同样是歌手名（MusicSiren.cpp 的 QHash<QString, ...>），所以条目集合与顺序一致，
// 只有 ID 列的**字面值**不同。
library;

import 'dart:convert';

import '../../basic/basic_models.dart';
import '../../data/storage/preference_store.dart';
import 'catalog_artist.dart';

/// Qt `constexpr int pageSize = 30`（MusicSiren.cpp:150 附近，searchSirenLocal）。
const int catalogSearchPageSize = 30;

/// Qt 的四种检索分类顺序（NativeHudSearch.cpp:63 `kinds`，也等于
/// `lib/hud/modals/search_modal.dart` 的 `kSearchKinds`）。
const List<String> catalogSearchKinds = <String>['song', 'album', 'playlist', 'artist'];

/// 最近搜索的偏好键（Qt MusicLibrary.cpp:107 / :697 的 `"search-history"`）。
const String catalogSearchHistoryKey = 'search-history';

/// Qt 的最近搜索上限（MusicLibrary.cpp:108 `searchHistory.size() < 12` 与
/// :699 `while (searchHistory.size() > 12)`）。
const int catalogSearchHistoryLimit = 12;

/// 检索平台名：塞壬曲库（Qt 里 `provider` 字段即此串）。
const String catalogSearchProvider = 'siren';

/// 一次检索的分页结果。
///
/// 字段逐项对齐 Qt MusicLibrary 的 `lists[0] / totals[0] / hasMore[0] / status`
/// ——UI 不需要自己再拼状态串，也不需要自己判断「有没有下一页」。
class SearchOutcome {
  const SearchOutcome({
    required this.items,
    required this.total,
    required this.hasMore,
    required this.status,
    required this.kind,
    required this.query,
    required this.start,
  });

  /// 本页条目（Qt 的 `lists[0]`，元素形状见本文件顶部的说明）。
  final List<Map<String, Object?>> items;

  /// 命中总数（Qt 的 `totals[0]`），不是本页条数。
  final int total;

  /// 是否还有下一页（Qt 的 `hasMore[0]`）。
  final bool hasMore;

  /// Qt 的状态串（空页/有结果两个分支）。
  final String status;

  /// 本次检索的分类（song/album/playlist/artist）。
  final String kind;

  /// 本次检索的关键词原文（未 trim 的入参）。
  final String query;

  /// 本页起始下标。
  final int start;

  /// 下一页的起始下标（Qt 的 `searchCursor = start + page.size()`）。
  int get cursor => start + items.length;

  /// 空页判定（Qt：`page.isEmpty()`）。
  bool get isEmpty => items.isEmpty;

  SearchOutcome copyWith({List<Map<String, Object?>>? items, bool? hasMore}) => SearchOutcome(
    items: items ?? this.items,
    total: total,
    hasMore: hasMore ?? this.hasMore,
    status: status,
    kind: kind,
    query: query,
    start: start,
  );

  @override
  String toString() =>
      'SearchOutcome(kind: $kind, start: $start, items: ${items.length}, total: $total, hasMore: $hasMore)';
}

/// 曲库分类检索索引：构造期一次建好歌手归并表，之后按需分页。
///
/// 曲库是内存数据（塞壬唱片），不涉及网络、并发或持久化：本类只做过滤与分页。
class CatalogSearchIndex {
  CatalogSearchIndex({
    required SirenCatalog catalog,
    this.playlists = const <BasicLocalPlaylist>[],
    this.provider = catalogSearchProvider,
  }) : _songs = catalog.songs,
       _albums = catalog.albums,
       // 歌手归并在构造期一次完成（catalog_artist.dart 的契约）；投影只做
       // SirenSong → Map 的形状变换，不重复实现归并逻辑。
       _artists = CatalogArtistIndex(<Map<String, Object?>>[
         for (final SirenSong song in catalog.songs) _songArtistSource(song),
       ]);

  final List<SirenSong> _songs;
  final List<SirenAlbum> _albums;
  /// 本地自建歌单（Qt 的 `lists[2]`）；歌单分类只匹配它的标题。
  final List<BasicLocalPlaylist> playlists;
  final CatalogArtistIndex _artists;
  final String provider;

  /// 曲库歌曲数（Qt `lists[3].size()` 的口径）。
  int get songCount => _songs.length;

  /// 曲库专辑数（Qt `lists[4].size()`）。
  int get albumCount => _albums.length;

  /// 本地自建歌单数（Qt `lists[2].size()`）。
  int get playlistCount => playlists.length;

  /// Qt `query.trimmed().toLower()`：比较用的归一化文本。
  static String normalizeQuery(String query) => query.trim().toLowerCase();

  /// Qt 的 `matches(v)`：空关键词匹配一切，否则大小写不敏感子串。
  ///
  /// 注意 `String.toLowerCase()` 与 Qt 的 `QString::toLower()` 都按 Unicode
  /// 默认大小写映射，本场景（曲名/歌手名）结论一致。
  static bool _matches(String text, String value) =>
      text.isEmpty || value.toLowerCase().contains(text);

  /// Qt 的 `MusicData::slice(results, start, pageSize)`：越界下界夹到 0，
  /// 起点在区间外时返回空页（不是抛出）。
  static List<Map<String, Object?>> _slice(
    List<Map<String, Object?>> values,
    int start,
    int size,
  ) {
    if (values.isEmpty) {
      return <Map<String, Object?>>[];
    }
    final int from = start < 0 ? 0 : (start > values.length ? values.length : start);
    final int to = from + size > values.length ? values.length : from + size;
    if (to <= from) {
      return <Map<String, Object?>>[];
    }
    return values.sublist(from, to);
  }

  /// 把歌曲投影成 [CatalogArtistIndex] 需要的形状。
  ///
  /// [SirenSong.artist] 是 ' / ' 连接的作者串（lib/basic/basic_models.dart 的
  /// 构造约定），与 Qt 的 `artists[]` 数组同源；按 ' / ' 拆开并保留原文
  /// （归并键是**精确名字**，不做 trim/大小写折叠——见 catalog_artist.dart）。
  static Map<String, Object?> _songArtistSource(SirenSong song) => <String, Object?>{
    'id': song.id,
    'title': song.title,
    'album': song.album,
    'artist': _artistNames(song.artist),
  };

  static List<String> _artistNames(String artist) {
    if (artist.isEmpty) {
      return const <String>[];
    }
    final List<String> names = artist.split(' / ');
    final List<String> trimmed = <String>[
      for (final String name in names)
        if (name.trim().isNotEmpty) name,
    ];
    return trimmed;
  }

  /// 歌曲分类：Qt 的 title / album / artist 三处任一命中。
  SearchOutcome searchSongs(String query, {int start = 0}) {
    final String text = normalizeQuery(query);
    final List<Map<String, Object?>> results = <Map<String, Object?>>[
      for (final SirenSong song in _songs)
        if (_matches(text, song.title) || _matches(text, song.album) || _matches(text, song.artist))
          _songItem(song),
    ];
    return _outcome('song', query, start, results);
  }

  /// 专辑分类：Qt 的 title / artist 两处（**不**看曲目名）。
  SearchOutcome searchAlbums(String query, {int start = 0}) {
    final String text = normalizeQuery(query);
    final List<Map<String, Object?>> results = <Map<String, Object?>>[
      for (final SirenAlbum album in _albums)
        if (_matches(text, album.name) || _matches(text, album.artist)) _albumItem(album),
    ];
    return _outcome('album', query, start, results);
  }

  /// 歌手分类：按歌手名归并（[CatalogArtistIndex]）后过滤歌手名本身。
  SearchOutcome searchArtists(String query, {int start = 0}) {
    final List<CatalogArtist> artists = _artists.search(query);
    final List<Map<String, Object?>> results = <Map<String, Object?>>[
      for (final CatalogArtist artist in artists) _artistItem(artist),
    ];
    return _outcome('artist', query, start, results);
  }

  /// 歌单分类：Qt 只匹配标题（MusicSiren.cpp 的 playlist 分支过滤 `lists[2]`）。
  SearchOutcome searchPlaylists(String query, {int start = 0}) {
    final String text = normalizeQuery(query);
    final List<Map<String, Object?>> results = <Map<String, Object?>>[
      for (final BasicLocalPlaylist playlist in playlists)
        if (_matches(text, playlist.title)) _playlistItem(playlist),
    ];
    return _outcome('playlist', query, start, results);
  }

  /// 按分类分发；未知分类返回空页（Qt 的 `kinds.value(...)` 兜底是 "song"，
  /// 但那是**动作层**的兜底，领域层不替调用方猜）。
  SearchOutcome search({required String kind, required String query, int start = 0}) {
    switch (kind) {
      case 'song':
        return searchSongs(query, start: start);
      case 'album':
        return searchAlbums(query, start: start);
      case 'artist':
        return searchArtists(query, start: start);
      case 'playlist':
        return searchPlaylists(query, start: start);
      default:
        return SearchOutcome(
          items: const <Map<String, Object?>>[],
          total: 0,
          hasMore: false,
          status: '没有匹配的音乐',
          kind: kind,
          query: query,
          start: start,
        );
    }
  }

  /// Qt 分页收尾：切页、算游标/是否还有、拼状态串（MusicSiren.cpp:150-190）。
  SearchOutcome _outcome(
    String kind,
    String query,
    int start,
    List<Map<String, Object?>> results,
  ) {
    final int total = results.length;
    final List<Map<String, Object?>> page = _slice(results, start, catalogSearchPageSize);
    return SearchOutcome(
      items: page,
      total: total,
      hasMore: page.isNotEmpty && start + page.length < total,
      status: page.isEmpty
          ? (kind == 'playlist' ? '没有匹配的本地歌单' : '没有匹配的音乐')
          : '找到 $total 条结果',
      kind: kind,
      query: query,
      start: start,
    );
  }

  /// 行条目形状与 Qt `MusicData::item(...)` 的投影一致，供 HUD 直接消费：
  /// id / title / artist / album / cover / kind / key / provider。
  Map<String, Object?> _songItem(SirenSong song) => <String, Object?>{
    'provider': provider,
    'kind': 'song',
    'id': song.id,
    'key': song.key,
    'title': song.title,
    'artist': song.artist,
    'album': song.album,
    'albumID': song.albumId,
    'cover': song.cover,
    'durationMs': song.durationMs,
    'playable': song.playable,
  };

  Map<String, Object?> _albumItem(SirenAlbum album) => <String, Object?>{
    'provider': provider,
    'kind': 'album',
    'id': album.id,
    'key': album.key,
    'title': album.name, // SirenAlbum 的字段名是 name，Qt item 的字段名是 title。
    'artist': album.artist,
    'cover': album.cover,
    'trackCount': album.songCount,
  };

  Map<String, Object?> _artistItem(CatalogArtist artist) => <String, Object?>{
    'provider': provider,
    'kind': 'artist',
    'id': artist.id, // 'artist:<名字>'，见文件头的已知差异说明。
    'key': 'siren:artist:${artist.name}',
    'title': artist.name,
    'artist': artist.name,
    'artists': <Object?>[
      <String, Object?>{'id': artist.id, 'name': artist.name},
    ],
    'cover': _coverForArtist(artist.name),
    'trackCount': artist.trackCount,
  };

  Map<String, Object?> _playlistItem(BasicLocalPlaylist playlist) => <String, Object?>{
    'provider': provider,
    'kind': 'playlist',
    'id': playlist.id,
    'key': 'siren:playlist:${playlist.id}',
    'title': playlist.title,
    'artist': provider,
    'trackCount': playlist.trackCount,
  };

  /// Qt 建歌手条目时 `item["cover"] = song["cover"]`（首次出现那首歌的封面）。
  /// [CatalogArtist] 不携带封面，所以这里按归并键回查第一首命中歌曲。
  String _coverForArtist(String name) {
    for (final SirenSong song in _songs) {
      for (final String candidate in _artistNames(song.artist)) {
        if (candidate == name) {
          return song.cover;
        }
      }
    }
    return '';
  }
}

/// 最近搜索白名单（Qt MusicLibrary 的 `searchHistory`）。
///
/// 读写都走 [PreferenceStore]：键名 `search-history`，落盘前缀 `panel/`、
/// 白名单与长度闸门由商店负责（Bin/data/storage/preference_store.dart）。
class CatalogSearchHistory {
  const CatalogSearchHistory(this.store);

  final PreferenceStore store;

  /// Qt MusicLibrary.cpp:107-110：JSON 数组里只收字符串，读满 12 条即停。
  Future<List<String>> load() async {
    final String raw = await store.read(catalogSearchHistoryKey);
    if (raw.isEmpty) {
      return <String>[];
    }
    Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } catch (_) {
      // Qt 对不可解析的值得到空 QJsonArray；损坏的偏好不能让检索页崩掉。
      return <String>[];
    }
    if (decoded is! List) {
      return <String>[];
    }
    final List<String> history = <String>[];
    for (final Object? entry in decoded) {
      if (entry is String && history.length < catalogSearchHistoryLimit) {
        history.add(entry);
      }
    }
    return history;
  }

  /// Qt MusicLibrary.cpp:693-701 的写回：同名条目全部移除 → 置顶 → 截断 12 条
  /// → 以紧凑 JSON 数组写回。返回写回后的列表，方便调用方直接上屏。
  Future<List<String>> remember(String query) async {
    final List<String> history = await load();
    while (history.remove(query)) {
      // Qt QStringList::removeAll：同名条目全部移除后再置顶。
    }
    history.insert(0, query);
    while (history.length > catalogSearchHistoryLimit) {
      history.removeLast();
    }
    await store.write(catalogSearchHistoryKey, jsonEncode(history));
    return history;
  }
}
