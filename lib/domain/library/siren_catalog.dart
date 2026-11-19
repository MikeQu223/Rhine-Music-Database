part of 'music_library.dart';

// 塞壬唱片目录与本地检索（Qt/src/MusicSiren.cpp 全文，1-335 行）
//
// 逐函数对齐关系（每个函数头都标注 Qt 行号）：
//   1  librarySirenReloadCollections <- MusicSiren.cpp:7-23
//   2  librarySirenLoadCatalog       <- MusicSiren.cpp:28-88
//   3  librarySirenSearchLocal       <- MusicSiren.cpp:91-190
//   4  libraryOpenSirenAllSongs      <- MusicSiren.cpp:193-246
//   5  librarySirenLoadSource        <- MusicSiren.cpp:251-335
//
// 贯穿本文件的硬语义（全部照抄 Qt，不做"改良"）：
//  * 曲库数量完全由上游 /api/songs、/api/albums 决定，文案固定为
//    "已加载塞壬唱片曲库：<n> 首 / <m> 张专辑"（MusicSiren.cpp:78-79）。
//    仓库里出现的 933 只是 Qt UI 颜色常量 [0.973,0.969,0.933]，与曲库无关；
//    本文件不写死任何曲库数量（933/303 一律不出现）。
//  * 异步回包一律用 accountGeneration 现场校验：Qt MusicApi::send 在 valid()
//    为假时**根本不回调**（Qt/src/MusicApi.cpp:98-100），因此过期响应要整体
//    丢弃、连 loading 标记都不复位（MusicSiren.cpp:56 的 sirenCatalogLoading =
//    false 在回调体内，回调不发生时它就不执行）。
//  * 本地检索分页固定 30 条/页（MusicSiren.cpp:170 constexpr pageSize = 30），
//    与 MusicBridge/client/siren.mjs:8 的 PAGE_SIZE = 30 同值。
//
// 动态接续改用 Future/await 表达，但**入口函数的调用顺序与 Qt 逐行一致**：
// Qt 的 loadSirenCatalog()/search()/loadMoreSource() 都是 void 同步返回，
// 所以这里凡是"Qt 里是同步调用"的位置一律用 unawaited(...) 触发，
// 保证 changed()/状态写入的先后与 Qt 相同。
//

/// Qt MusicSiren.cpp:7-23 MusicLibrary::reloadSirenCollections。
///
/// 本地收藏与自建歌单（LocalCollections，仅存本机）：喜欢列表清空后由
/// likedCursor 从 0 重新分页读取，歌单列表一次性灌入且 hasMore[2] 恒为 false。
Future<void> librarySirenReloadCollections(MusicLibrary lib) async {
  if (!lib.isSiren) {
    return;
  }
  final SirenCollectionsPort? collections = lib.collections;
  if (collections == null) {
    return;
  }
  // Qt: const auto ids = collections->likedIDs();
  final List<String> ids = collections.likedIds();
  lib.likedIds = List<String>.from(ids);
  lib.likedCursor = 0;
  lib.lists[1] = <JsonMap>[];
  lib.totals[1] = ids.length;
  lib.hasMore[1] = ids.isNotEmpty;
  lib.lists[2] = collections.playlists();
  lib.totals[2] = lib.lists[2].length;
  lib.hasMore[2] = false;
  lib.sourceErrors[1] = '';
  lib.sourceErrors[2] = '';
  lib.changed();
}

/// Qt MusicSiren.cpp:28-88 MusicLibrary::loadSirenCatalog。
///
/// 每次启动只向官网取一次全量目录；之后检索、播放全部与资料库浏览都用这份
/// 本地数据。曲库已就绪时直接回填 3/4 栏并重放挂起的检索。
Future<void> librarySirenLoadCatalog(MusicLibrary lib) async {
  if (!lib.isSiren) {
    return;
  }
  if (lib.sirenSongs.isNotEmpty) {
    lib.lists[3] = lib.sirenSongs;
    lib.lists[4] = lib.sirenAlbums;
    lib.totals[3] = lib.lists[3].length;
    lib.totals[4] = lib.lists[4].length;
    lib.hasMore[3] = false;
    lib.hasMore[4] = false;
    // Qt: search(keyword, searchKind, false)。kind 非空 => librarySearch 不排队，
    // 与 Qt 的同步 search() 一致；此处不 await，保持 changed() 的先后顺序。
    if (lib.pendingSirenSearch) {
      lib.pendingSirenSearch = false;
      unawaited(librarySearch(lib, lib.keyword, kind: lib.searchKind));
    }
    lib.changed();
    return;
  }
  if (lib.sirenCatalogLoading) {
    return;
  }
  lib.sirenCatalogLoading = true;
  lib.status = '正在读取塞壬唱片曲库…';
  lib.changed();
  final int token = lib.accountGeneration;
  // Qt: api.call("catalog", {}, ...) => /native/siren/catalog，args 为空数组。
  final MusicReply reply = await lib.api.call(
    'catalog',
    const <Object?>[],
    valid: () => token == lib.accountGeneration,
  );
  // Qt MusicApi::send 在 valid() 为假时不回调：整体丢弃，且**不复位**
  // sirenCatalogLoading（MusicSiren.cpp:56 在该回调体内）。
  if (token != lib.accountGeneration || isStale(reply)) {
    return;
  }
  lib.sirenCatalogLoading = false;
  if (!reply.ok) {
    lib.pendingSirenSearch = false;
    lib.sourceErrors[3] = reply.error ?? '';
    lib.sourceErrors[4] = reply.error ?? '';
    lib.hasMore[3] = true;
    lib.hasMore[4] = true;
    lib.status = '塞壬唱片曲库读取失败：' + (reply.error ?? '');
    lib.changed();
    return;
  }
  // Qt: value["songs"].toArray() / value["albums"].toArray()。
  // MusicBridge/client/siren.mjs:310-316 的 catalog() 正是 {songs, albums}。
  final JsonMap value = mapOf(reply.value);
  lib.sirenSongs = mapsOf(value['songs']);
  lib.sirenAlbums = mapsOf(value['albums']);
  lib.lists[3] = lib.sirenSongs;
  lib.lists[4] = lib.sirenAlbums;
  lib.totals[3] = lib.lists[3].length;
  lib.totals[4] = lib.lists[4].length;
  lib.hasMore[3] = false;
  lib.hasMore[4] = false;
  lib.sourceErrors[3] = '';
  lib.sourceErrors[4] = '';
  lib.status = '已加载塞壬唱片曲库：' +
      lib.totals[3].toString() +
      ' 首 / ' +
      lib.totals[4].toString() +
      ' 张专辑';
  if (lib.pendingSirenSearch) {
    lib.pendingSirenSearch = false;
    unawaited(librarySearch(lib, lib.keyword, kind: lib.searchKind));
  } else {
    lib.changed();
  }
}

/// Qt MusicSiren.cpp:91-190 MusicLibrary::searchSirenLocal。
///
/// 塞壬的本地检索：在内存曲库里过滤，曲库未就绪时先加载、完成后自动重放这次
/// 检索。调用方（根文件 sirenSearchLocal / search_controller 的 isSiren 分支）
/// 已经按 Qt MusicLibrary.cpp:462-475 写好了 keyword/searchKind/分页清空与
/// 最近搜索白名单，本函数只承担 Qt searchSirenLocal 的那一段。
Future<void> librarySirenSearchLocal(
  MusicLibrary lib,
  String query,
  String kind,
  int start,
  bool more,
) async {
  // Qt: 网络曲库尚未就绪时，用会话恢复的列表兜底。
  if (lib.sirenSongs.isEmpty && lib.lists[3].isNotEmpty) {
    lib.sirenSongs = lib.lists[3];
    lib.sirenAlbums = lib.lists[4];
  }
  if (lib.sirenSongs.isEmpty) {
    lib.pendingSirenSearch = true;
    lib.searchLoading = false;
    lib.status = '正在读取塞壬唱片曲库…';
    // Qt 是同步调用 loadSirenCatalog()：它跑到 api.call 才挂起，
    // 因此这里也必须 unawaited，才能让随后的 changed() 贴在它之后。
    unawaited(librarySirenLoadCatalog(lib));
    lib.changed();
    return;
  }
  // Qt: query.trimmed().toLower()；matches() 用 toLower().contains()。
  final String text = query.trim().toLowerCase();
  bool matches(String value) => text.isEmpty || value.toLowerCase().contains(text);
  final List<JsonMap> results = <JsonMap>[];
  if (kind == 'song') {
    for (final JsonMap item in lib.sirenSongs) {
      if (matches(textOf(item['title'])) ||
          matches(textOf(item['album'])) ||
          matches(textOf(item['artist']))) {
        results.add(item);
      }
    }
  } else if (kind == 'album') {
    for (final JsonMap item in lib.sirenAlbums) {
      if (matches(textOf(item['title'])) || matches(textOf(item['artist']))) {
        results.add(item);
      }
    }
  } else if (kind == 'artist') {
    // Qt 用 QHash<QString, QJsonObject> 按**歌手名**聚合（不是 id）：
    // 同名歌手合并为一条，trackCount 为该曲库里出现的歌曲数。
    final Map<String, JsonMap> artists = <String, JsonMap>{};
    for (final JsonMap song in lib.sirenSongs) {
      for (final JsonMap artist in mapsOf(song['artists'])) {
        final String name = textOf(artist['name']);
        if (name.isEmpty) {
          continue;
        }
        JsonMap? item = artists[name];
        if (item == null) {
          // Qt: MusicData::item("artist", artist["id"], name, {}, provider)。
          // artist["id"] 由 siren.mjs:28-30 artistID() 生成：'a'+sha1(name)[0:16]，
          // key 因此是 'siren:artist:<那个 id>'。
          item = musicItem(
            kind: 'artist',
            id: textOf(artist['id']),
            title: name,
            artist: name,
            provider: lib.provider,
          );
          item['artist'] = name;
          item['artists'] = <Object?>[artist];
          // 上游 catalog 的 cover 恒为字符串（siren.mjs:209/248），
          // textOf 与 Qt 的 QJsonValue 拷贝等价，且不会用 null 覆盖 item() 的默认值。
          item['cover'] = textOf(song['cover']);
          item['trackCount'] = 0;
        }
        item['trackCount'] = intOf(item['trackCount']) + 1;
        artists[name] = item;
      }
    }
    final List<JsonMap> list = <JsonMap>[
      for (final MapEntry<String, JsonMap> entry in artists.entries)
        if (matches(entry.key)) entry.value,
    ];
    // Qt std::sort：trackCount 降序，相同则 title 升序（QString::operator< 即
    // UTF-16 码位比较，与 Dart String.compareTo 一致）。Qt 的 QHash 迭代无序、
    // 并列项的先后本来不确定；这里按插入序（首次出现序）决定，比 Qt 更确定。
    list.sort((JsonMap left, JsonMap right) {
      final int a = intOf(left['trackCount']);
      final int b = intOf(right['trackCount']);
      if (a != b) {
        return b.compareTo(a);
      }
      return textOf(left['title']).compareTo(textOf(right['title']));
    });
    results.addAll(list);
  } else if (kind == 'playlist') {
    // Qt 直接过滤 lists[2]（本地自建歌单），条目的 key 形如 'siren:playlist:<id>'。
    for (final JsonMap item in lib.lists[2]) {
      if (matches(textOf(item['title']))) {
        results.add(item);
      }
    }
  }
  const int pageSize = 30;
  final int total = results.length;
  // Qt MusicData::slice(results, start, pageSize)。
  final List<JsonMap> page = sliceItems(results, start, pageSize);
  lib.lists[0] = more ? uniqueItems(lib.lists[0], page) : page;
  if (!more) {
    lib.offsets[0] = 0;
  }
  lib.searchCursor = start + page.length;
  lib.hasMore[0] = page.isNotEmpty && start + page.length < total;
  lib.totals[0] = total;
  lib.searchLoading = false;
  lib.status = page.isEmpty
      ? (kind == 'playlist' ? '没有匹配的本地歌单' : '没有匹配的音乐')
      : '找到 ' + total.toString() + ' 条结果';
  if (!more) {
    // Qt: showSource(0); emit modeRequested("archive"); frame["mode"] = "archive";
    lib.showSource(0);
    lib.modeRequests.add('archive');
    lib.frame['mode'] = 'archive';
  }
  lib.changed();
}

/// Qt MusicSiren.cpp:193-246 MusicLibrary::openSirenAllSongs。
///
/// 把全量歌曲作为一个虚拟歌单打开到资料库。条目是手写对象而非 musicItem()：
/// key 固定为 'siren:playlist:all'（不带 provider 前缀），id 固定 'siren-all'。
Future<bool> libraryOpenSirenAllSongs(MusicLibrary lib) async {
  if (!lib.isSiren || lib.lists[3].isEmpty) {
    lib.status = '塞壬唱片曲库尚未加载';
    lib.changed();
    return false;
  }
  lib.directoryGeneration++;
  lib.selectionGeneration++;
  lib.wikiGeneration++;
  // Qt: frame["selected"].toInt(physicalSlots[selectedLane].value(0, -1))
  // —— QJsonValue::toInt(默认值) 只认数值，故用 _jsonToInt 传默认值。
  final List<int> laneSlots = (lib.selectedLane >= 0 && lib.selectedLane < lib.physicalSlots.length)
      ? lib.physicalSlots[lib.selectedLane]
      : const <int>[];
  final int physical = lib.selectedPhysical >= 0
      ? lib.selectedPhysical
      : _jsonToInt(lib.frame['selected'], slotValue(laneSlots, 0, -1));
  final JsonMap item = <String, Object?>{
    'provider': lib.provider,
    'kind': 'playlist',
    'virtual': true,
    'id': 'siren-all',
    'key': 'siren:playlist:all',
    'title': '全部歌曲',
    'artist': lib.providerName(),
    'cover': textOf(lib.lists[3].first['cover']),
    'description': '塞壬唱片全部歌曲',
    'trackCount': lib.lists[3].length,
  };
  final DirectoryFolder next = DirectoryFolder(
    parent: lib.directory,
    item: item,
    // Qt 的 QJsonArray 赋值是隐式共享 + 写时分离，等价于复制一份列表。
    songs: List<JsonMap>.of(lib.lists[3]),
  );
  for (final JsonMap song in lib.lists[3]) {
    next.ids.add(itemIdOf(song));
  }
  next.cursor = next.ids.length;
  next.parentPhysical = physical;
  next.parentLane = lib.selectedLane;
  next.parentItem = lib.current;
  lib.directory = next;
  lib.directoryInfo = false;
  lib.directoryLoading = false;
  lib.wantsSongDetails = false;
  lib.current = <String, Object?>{};
  lib.tracks = <JsonMap>[];
  lib.trackIds = <String>[];
  lib.coverImage = '';
  lib.coverKey = '';
  lib.detailLoading = false;
  lib.modeRequests.add('archive');
  lib.navigationRequests.add(const LibraryNavigation('lane', 1));
  final int destination = (lib.selectedLane + 1) % 5;
  next.anchor = destination * 8 + lib.rowMemory[destination];
  lib.selectedPhysical = -1;
  lib.status = '已打开：全部歌曲';
  next.index = 0;
  // Qt 的 choose() 是 void：调用点不等它，这里照抄（unawaited 而非 await）。
  // choose 在第一个 await 之前就写完 current 并 changed()，因此调用方
  // await openSirenAllSongs() 之后看到的状态与 Qt 完全一致。
  unawaited(lib.choose(lib.lists[3].first));
  return true;
}

/// Qt MusicSiren.cpp:251-335 MusicLibrary::loadSirenSource。
///
/// 喜欢与歌单读取本地存储：
///  * lane 2 一次性灌入本地歌单；
///  * lane 3/4 交给曲库（未就绪则先加载）；
///  * lane 1（喜欢）按 100 条/页取本地 id 再走 /native/siren/songs 换条目。
Future<void> librarySirenLoadSource(MusicLibrary lib, int lane) async {
  if (!lib.isSiren || lane < 1 || lane > 4) {
    return;
  }
  final SirenCollectionsPort? collections = lib.collections;
  if (lane == 2) {
    lib.lists[2] = collections != null ? collections.playlists() : <JsonMap>[];
    lib.totals[2] = lib.lists[2].length;
    lib.hasMore[2] = false;
    lib.sourceErrors[2] = '';
    lib.status = lib.lists[2].isEmpty ? '暂无本地歌单，可点击创建歌单' : '已读取本地歌单';
    lib.changed();
    return;
  }
  if (lane == 3 || lane == 4) {
    // Qt 这一段没有 changed()：曲库就绪时只把 hasMore 落下，未就绪时由
    // loadSirenCatalog 自己通知。
    if (lib.lists[lane].isEmpty) {
      unawaited(librarySirenLoadCatalog(lib));
    } else {
      lib.hasMore[lane] = false;
    }
    return;
  }
  // 到这里 lane == 1（喜欢）。
  if (lib.personalLoading) {
    lib._pendingLane = lane;
    return;
  }
  if (!lib.hasMore[lane]) {
    return;
  }
  lib.personalLoading = true;
  lib.sourceErrors[lane] = '';
  lib.changed();
  final int token = lib.accountGeneration;
  final List<String> all = collections != null ? collections.likedIds() : <String>[];
  // Qt QStringList::mid(likedCursor, 100)。
  final List<String> page = sliceStrings(all, lib.likedCursor, 100);
  if (page.isEmpty) {
    lib.personalLoading = false;
    lib.hasMore[1] = false;
    lib.totals[1] = all.length;
    lib.status = all.isEmpty ? '暂无喜欢的歌曲' : '已读取喜欢的歌曲';
    if (lib._playLiked) {
      lib._playLiked = false;
      lib.playDirectory();
    }
    lib.changed();
    return;
  }
  final MusicReply reply = await lib.api.call(
    'songs',
    <Object?>[page],
    valid: () => token == lib.accountGeneration,
  );
  if (token != lib.accountGeneration || isStale(reply)) {
    return;
  }
  lib.personalLoading = false;
  if (!reply.ok) {
    lib._playLiked = false;
    lib.sourceErrors[1] = reply.error ?? '';
    lib.status = reply.error ?? '';
    lib.changed();
    return;
  }
  lib.lists[1] = uniqueItems(lib.lists[1], mapsOf(reply.value));
  lib.likedCursor += page.length;
  final int total = collections != null ? collections.likedIds().length : lib.likedCursor;
  lib.totals[1] = total;
  lib.hasMore[1] = lib.likedCursor < total;
  lib.status = '已读取喜欢的歌曲';
  if (lib._playLiked) {
    if (lib.hasMore[1]) {
      unawaited(lib.loadMoreSource(1));
    } else {
      lib._playLiked = false;
      lib.playDirectory();
    }
  }
  if (lib.selectedLane == 1 && lib.current.isEmpty && lib.lists[1].isNotEmpty) {
    lib.selectedPhysical = -1;
    // Qt: observe(frame["selected"].toInt(physicalSlots[1].value(0, -1)))
    lib.observe(_jsonToInt(lib.frame['selected'], slotValue(lib.physicalSlots[1], 0, -1)));
  }
  final int pending = lib._pendingLane;
  lib._pendingLane = -1;
  if (pending > 0 && pending != 1 && lib.lists[pending].isEmpty) {
    unawaited(lib.loadMoreSource(pending));
  }
  lib.changed();
}
