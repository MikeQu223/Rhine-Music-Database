part of 'music_library.dart';

// ---------------------------------------------------------------------------
// 目录栈（Qt/src/MusicDirectory.cpp 全文 + Qt/src/MusicLibrary.cpp 的目录成员）
//
// 逐函数对齐关系（本文件每段都标注 Qt 行号）：
//   1  orderedSongs/updateSongs 归 DirectoryFolder（根文件 music_library.dart）；
//   2  setDirectorySort      <- MusicDirectory.cpp:33-43
//   3  enterDirectory        <- MusicDirectory.cpp:46-142
//   4  openDaily             <- MusicDirectory.cpp:147-209
//   5  loadArtistAlbums      <- MusicDirectory.cpp:211-234
//   6  openSongArtist        <- MusicDirectory.cpp:236-253
//   7  observeDirectory      <- MusicDirectory.cpp:255-300
//   8  selectDirectory       <- MusicDirectory.cpp:302-319
//   9  navigateDirectory     <- MusicDirectory.cpp:321-340
//  10  loadDirectoryPage     <- MusicDirectory.cpp:343-377
//  11  showDirectoryInfo     <- MusicDirectory.cpp:379-398
//  12  returnToDirectory     <- MusicDirectory.cpp:401-415
//  13  leaveDirectory        <- MusicDirectory.cpp:417-452
//  14  followPlayback        <- MusicDirectory.cpp:455-503
//
// 三条贯穿全文件的硬语义：
//  * 物理网格是 5 列 x 8 行 = 40 格，选中项由 (index + anchor) % 40 定位
//    （MusicSession.cpp:260 把选中槽位夹取到 0..39，即 40 格）。
//  * 每次异步回调都用 directoryGeneration 现场校验：Qt MusicApi::send 在
//    valid() 为假时根本不回调（Qt/src/MusicApi.cpp:98-100），所以过期响应
//    必须整体丢弃，且不清理 loading 标记（Qt 里那些标记只在
//    enterDirectory/leaveDirectory 里复位）。
//  * 物理索引一律照抄 QVector::value(index, fallback) 语义。
//
// 仓库本阶段禁止运行验证：本文件未执行 flutter analyze / flutter test
// （RED/GREEN 均未执行）。
// ---------------------------------------------------------------------------

/// Qt QVector::value(index, fallback)：越界给默认值。
int directorySlotValue(List<int> slots, int index, int fallback) {
  return (index >= 0 && index < slots.length) ? slots[index] : fallback;
}

/// Qt 取某一栏的物理槽位（selectedLane 恒在 0..4，防御性取值不改变语义）。
List<int> directoryLaneSlots(MusicLibrary lib, int lane) {
  if (lane < 0 || lane >= lib.physicalSlots.length) {
    return const <int>[];
  }
  return lib.physicalSlots[lane];
}

/// Qt QStringList::value(lane)：越界给空串（MusicDirectory.cpp:450）。
String directoryColumnValue(List<String> columns, int lane) {
  return (lane >= 0 && lane < columns.length) ? columns[lane] : '';
}

/// Qt frame["selected"].toInt(physicalSlots[selectedLane].value(0, -1))：
/// QJsonValue::toInt 只认数值，字符串一律落到默认值（MusicDirectory.cpp:59）。
int directoryFrameSelected(MusicLibrary lib) {
  return _jsonToInt(
    lib.frame['selected'],
    directorySlotValue(directoryLaneSlots(lib, lib.selectedLane), 0, -1),
  );
}

/// enterDirectory / openDaily / followPlayback 共用的物理位兜底：
/// 有真实选中就用它，否则回落到 frame 里的槽位。
int directoryResolvePhysical(MusicLibrary lib) {
  return lib.selectedPhysical >= 0 ? lib.selectedPhysical : directoryFrameSelected(lib);
}

/// 把 40 格网格的 cell 折算成物理槽位（cell ~/ 8 = 栏，cell % 8 = 行）。
int directoryPhysicalOfCell(MusicLibrary lib, int cell) {
  return directorySlotValue(directoryLaneSlots(lib, cell ~/ 8), cell % 8, -1);
}

/// Qt MusicDirectory.cpp:33-43 MusicLibrary::setDirectorySort：
/// 只对 playlist 目录生效，字段必须在白名单内；资料页同步刷新 tracks。
Future<void> librarySetDirectorySort(MusicLibrary lib, String field) async {
  final DirectoryFolder? folder = lib.directory;
  if (folder == null || itemKindOf(folder.item) != 'playlist') {
    return;
  }
  if (field != 'none' && field != 'title' && field != 'album' && field != 'artist') {
    return;
  }
  folder.updateSongs(folder.songs, field);
  if (lib.directoryInfo) {
    // Qt 是 QJsonArray 值语义拷贝。
    lib.tracks = List<JsonMap>.from(folder.orderedSongs());
  }
  lib.changed();
}

/// Qt MusicDirectory.cpp:46-142 MusicLibrary::enterDirectory：
/// 先建立可返回的父链与显示状态，再分渠道加载；代数变化后丢弃旧响应。
Future<void> libraryEnterDirectory(MusicLibrary lib, JsonMap value) async {
  if (value.isEmpty) {
    return;
  }
  if (itemKindOf(value) == 'song') {
    await lib.choose(value);
    return;
  }
  final int token = ++lib.directoryGeneration;
  lib.selectionGeneration++;
  lib.wikiGeneration++;
  final int physical = directoryResolvePhysical(lib);
  final DirectoryFolder next = DirectoryFolder(
    parent: lib.directory,
    item: value,
    albumsMore: itemKindOf(value) == 'artist',
    parentPhysical: physical,
    parentLane: lib.selectedLane,
    parentItem: value,
  );
  lib.directory = next;
  lib.directoryInfo = false;
  lib.directoryLoading = true;
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
  lib.status = '正在打开：' + textOf(value['title']);
  lib.changed();

  if (lib.isLocal) {
    final List<JsonMap> songs = lib.local?.tracks(value) ?? const <JsonMap>[];
    next.songs = songs;
    // Qt 的 next->item = value 是 QJsonObject 隐式共享拷贝：写 trackCount 不得穿透到调用方。
    next.item = <String, Object?>{...mapOf(next.item), 'trackCount': songs.length};
    for (final JsonMap song in songs) {
      next.ids.add(itemIdOf(song));
    }
    next.cursor = next.ids.length;
    next.albumsMore = false;
    lib.directoryLoading = false;
    if (songs.isNotEmpty) {
      await lib.choose(songs.first);
    }
    lib.changed();
    return;
  }

  if (lib.isSiren && itemKindOf(value) == 'playlist' && boolOf(value['localCollection'])) {
    final List<Object?> ids =
        lib.collections?.tracks(textOf(value['id'])) ?? const <String>[];
    next.ids = ids;
    next.songs = <JsonMap>[];
    next.cursor = 0;
    next.albumsMore = false;
    next.item = <String, Object?>{...mapOf(next.item), 'trackCount': ids.length};
    lib.directoryLoading = false;
    if (ids.isEmpty) {
      lib.status = '歌单暂无可读取曲目';
      lib.changed();
    } else {
      await libraryLoadDirectoryPage(lib, 0);
    }
    return;
  }

  final MusicReply reply = await lib.api.call(
    'detail',
    <Object?>[value],
    valid: () => token == lib.directoryGeneration,
  );
  if (token != lib.directoryGeneration || isStale(reply)) {
    return;
  }
  if (!reply.ok) {
    lib.directoryLoading = false;
    lib.status = '读取失败：' + (reply.error ?? '');
    lib.changed();
    return;
  }
  final Object? raw = reply.value;
  final List<Object?> values = raw is List ? raw.cast<Object?>() : const <Object?>[];
  final JsonMap item = values.isNotEmpty ? mapOf(values[0]) : <String, Object?>{};
  final List<JsonMap> songs = values.length > 1 ? mapsOf(values[1]) : <JsonMap>[];
  // Qt MusicDirectory.cpp:127：ids 原样保留 QJsonArray（数字 id 不能被丢弃）。
  final List<Object?> ids = values.length > 2 ? trackIdValuesOf(values[2]) : <Object?>[];
  next.item = item;
  next.songs = songs;
  next.ids = ids;
  next.cursor = cursorOf(songs, ids);
  lib.details[itemKeyOf(item)] = item;
  lib.directoryLoading = false;
  lib.status = '已打开：' + textOf(item['title']);
  if (itemKindOf(value) == 'artist') {
    await libraryShowDirectoryInfo(lib);
  } else if (songs.isNotEmpty) {
    next.index = 0;
    await lib.choose(songs.first);
  } else {
    lib.changed();
  }
}
/// Qt MusicDirectory.cpp:147-209 MusicLibrary::openDaily：
/// 发现页每日推荐开成虚拟歌单目录（parentItem 用 current，与 enterDirectory 不同）。
/// Qt 的 !discover 守卫在本移植里不可达：根文件 :1163 无条件构造 discover
/// （对应 Qt MusicLibrary.cpp:65 构造函数里无条件 make_unique<MusicDiscover>）。
Future<bool> libraryOpenDaily(MusicLibrary lib) async {
  final List<JsonMap> songs = <JsonMap>[
    for (final JsonMap value in lib.discover.items)
      if (itemKindOf(value) == 'song') value,
  ];
  if (songs.isEmpty) {
    lib.status = '每日推荐暂无可打开的歌曲';
    lib.changed();
    return false;
  }
  lib.directoryGeneration++;
  lib.selectionGeneration++;
  lib.wikiGeneration++;
  final int physical = directoryResolvePhysical(lib);
  final JsonMap item = <String, Object?>{
    'provider': lib.provider,
    'kind': 'playlist',
    'virtual': true,
    'id': 'daily',
    'key': lib.provider + ':playlist:daily',
    'title': lib.provider == 'qq' ? '每日 30 首' : '每日推荐',
    'artist': lib.providerName(),
    // Qt MusicDirectory.cpp:178 songs.first().toObject()["cover"].toString()：
    // 非字符串/缺失一律得到空串（textOf 与 QJsonValue::toString 同语义）。
    'cover': textOf(songs.first['cover']),
    'description': '来自发现音乐的每日推荐，打开后不会同步到账号歌单。',
    'trackCount': songs.length,
  };
  final DirectoryFolder next = DirectoryFolder(
    parent: lib.directory,
    item: item,
    songs: songs,
  );
  for (final JsonMap song in songs) {
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
  lib.status = '已打开：' + textOf(item['title']);
  next.index = 0;
  await lib.choose(songs.first);
  return true;
}

/// Qt MusicDirectory.cpp:211-234 MusicLibrary::loadArtistAlbums：
/// 专辑分页只在 artist 目录、未加载中且还有更多时请求。
Future<void> libraryLoadArtistAlbums(MusicLibrary lib) async {
  final DirectoryFolder? folder = lib.directory;
  if (lib.isLocal ||
      folder == null ||
      itemKindOf(folder.item) != 'artist' ||
      folder.albumsLoading ||
      !folder.albumsMore) {
    return;
  }
  folder.albumsLoading = true;
  lib.changed();
  final int token = lib.directoryGeneration;
  final MusicReply reply = await lib.api.call(
    'artistAlbums',
    <Object?>[folder.item['id'], folder.albumCursor],
    valid: () => token == lib.directoryGeneration,
  );
  if (token != lib.directoryGeneration || isStale(reply)) {
    return;
  }
  if (reply.ok) {
    final JsonMap page = mapOf(reply.value);
    folder.albums = uniqueItems(folder.albums, mapsOf(page['items']));
    folder.albumCursor += intOf(page['rawCount']);
    folder.albumsMore = boolOf(page['more']);
  } else {
    lib.status = '专辑读取失败：' + (reply.error ?? '');
  }
  folder.albumsLoading = false;
  lib.changed();
}

/// Qt MusicDirectory.cpp:236-253 MusicLibrary::openSongArtist：
/// local 走本地 artist 条目（不做 ID 校验），在线要求 ID 匹配 ^[a-zA-Z0-9_-]{1,80}$。
Future<void> libraryOpenSongArtist(MusicLibrary lib, [int index = 0]) async {
  final List<JsonMap> artists = mapsOf(lib.current['artists']);
  if (lib.isLocal) {
    final JsonMap artist =
        index >= 0 && index < artists.length ? artists[index] : <String, Object?>{};
    await libraryEnterDirectory(lib, <String, Object?>{
      'provider': 'local',
      'kind': 'artist',
      'id': artist['id'],
      'key': 'local:artist:' + textOf(artist['id']),
      'title': artist['name'],
    });
    return;
  }
  final JsonMap artist =
      index >= 0 && index < artists.length ? artists[index] : <String, Object?>{};
  final String id = textOf(artist['id']);
  if (artist.isNotEmpty && RegExp(r'^[a-zA-Z0-9_-]{1,80}$').hasMatch(id)) {
    await libraryEnterDirectory(
      lib,
      musicItem(kind: 'artist', id: id, title: textOf(artist['name']), provider: lib.provider),
    );
  }
}

/// Qt MusicDirectory.cpp:255-300 MusicLibrary::observeDirectory：
/// 目录模式下的物理槽位拖动：空目录只记锚点，跨页继续逻辑索引。
Future<void> libraryObserveDirectory(MusicLibrary lib, int physical) async {
  final DirectoryFolder? folder = lib.directory;
  if (folder == null || lib.directoryInfo || lib.selectedPhysical == physical) {
    return;
  }
  int lane = -1;
  // Qt MusicDirectory.cpp:261 固定扫描 5 栏。
  for (int i = 0; i < 5; i++) {
    if (directoryLaneSlots(lib, i).contains(physical)) {
      lane = i;
      break;
    }
  }
  if (lane < 0) {
    return;
  }
  final List<int> slots = directoryLaneSlots(lib, lane);
  final int row = slots.indexOf(physical);
  if (folder.songs.isEmpty) {
    lib.selectedPhysical = physical;
    lib.selectedLane = lane;
    folder.anchor = lane * 8 + row;
    return;
  }
  final int previousCell = (folder.index + folder.anchor) % 40;
  final int movement = lane == previousCell ~/ 8
      ? (row - previousCell % 8 + 12) % 8 - 4
      : (lane * 8 + row - previousCell + 60) % 40 - 20;
  if (movement == 0) {
    return;
  }
  final int target = folder.index + movement;
  final int count = folder.songs.length;
  final int index = target >= count && folder.cursor < folder.ids.length
      ? target
      : (target % count + count) % count;
  folder.anchor = (lane * 8 + row - index % 40 + 40) % 40;
  lib.selectedPhysical = physical;
  lib.selectedLane = lane;
  if (target >= count && folder.cursor < folder.ids.length) {
    await libraryLoadDirectoryPage(lib, target);
  } else {
    folder.index = index;
    folder.page = index ~/ 40 * 40;
    await lib.choose(folder.orderedSongs()[index]);
  }
}
/// Qt MusicDirectory.cpp:302-319 MusicLibrary::selectDirectory：
/// 物理槽位由 (index + anchor) % 40 决定；axis 为空时不发导航。
/// ⚠ Dart 不能同时有可选位置参数与命名参数，故 mode 为必填位置参数，
///   调用方需显式传 Qt 默认值 "archive"（Qt 头文件默认参数见 MusicLibrary.h:126-130）。
/// ⚠ 返回 Future 但函数体同步完成：Qt 在 choose 之后还要 emit modeRequested/changed，
///   用 unawaited 保持与 Qt 相同的同步发射顺序（不可改成 await）。
Future<void> librarySelectDirectory(
  MusicLibrary lib,
  int index,
  String mode, {
  String axis = 'row',
  int direction = 1,
}) async {
  final DirectoryFolder? folder = lib.directory;
  if (folder == null || index < 0 || index >= folder.songs.length) {
    return;
  }
  lib.directoryInfo = false;
  folder.index = index;
  folder.page = index ~/ 40 * 40;
  final int cell = (index + folder.anchor) % 40;
  lib.selectedLane = cell ~/ 8;
  final int physical = directoryPhysicalOfCell(lib, cell);
  final JsonMap navigation = axis.isEmpty
      ? <String, Object?>{}
      : <String, Object?>{'axis': axis, 'direction': direction};
  lib.selectionRequests.add((index: physical, navigation: navigation));
  lib.selectedPhysical = physical;
  // Qt choose(value, false, mode == "detail")：Dart 侧 containerDetails==null 即 Qt 的 false。
  unawaited(lib.choose(folder.orderedSongs()[index], showDetails: mode == 'detail'));
  lib.modeRequests.add(mode);
  lib.changed();
}

/// Qt MusicDirectory.cpp:321-340 MusicLibrary::navigateDirectory：
/// 越界且仍有未消费 id 时先补页；否则循环取模并转发给 selectDirectory。
/// axis 取 Qt 默认值 ""（MusicLibrary.h:128），空轴按 |step| 归一化为 row/lane。
Future<void> libraryNavigateDirectory(MusicLibrary lib, int step, [String axis = '']) async {
  final DirectoryFolder? folder = lib.directory;
  if (folder == null || folder.songs.isEmpty) {
    return;
  }
  final int target = folder.index + step;
  if (target >= folder.songs.length && folder.cursor < folder.ids.length) {
    await libraryLoadDirectoryPage(lib, target);
    return;
  }
  int direction = step > 0 ? 1 : -1;
  String resolvedAxis = axis;
  if (resolvedAxis == 'row') {
    direction = step;
  }
  if (resolvedAxis.isEmpty) {
    resolvedAxis = step.abs() > 1 ? 'lane' : 'row';
  }
  final int count = folder.songs.length;
  await librarySelectDirectory(
    lib,
    ((target % count) + count) % count,
    'archive',
    axis: resolvedAxis,
    direction: direction,
  );
}

/// Qt MusicDirectory.cpp:343-377 MusicLibrary::loadDirectoryPage：
/// 每页 100 条；游标按已消费 id 数推进；回调第一件事清 directoryLoading。
/// 过期响应（Qt MusicApi::send 在 valid() 为假时静默丢弃）整体丢弃：不改状态、不清 loading。
Future<void> libraryLoadDirectoryPage(MusicLibrary lib, [int? selectAfter]) async {
  final DirectoryFolder? folder = lib.directory;
  if (folder == null || lib.directoryLoading || folder.cursor >= folder.ids.length) {
    return;
  }
  lib.directoryLoading = true;
  final List<Object?> ids = sliceValues(folder.ids, folder.cursor, 100);
  lib.changed();
  final int token = lib.directoryGeneration;
  final MusicReply reply = await lib.api.call(
    'songs',
    <Object?>[ids],
    valid: () => token == lib.directoryGeneration,
  );
  if (token != lib.directoryGeneration || isStale(reply)) {
    return;
  }
  lib.directoryLoading = false;
  if (!reply.ok) {
    lib.status = reply.error ?? '';
    lib.changed();
    return;
  }
  // ids 保持原始 JSON 类型（可能含数字 id），由 orderedItems 内部按
  // identifierOf 归一后匹配曲目（Qt MusicData::ordered 的 id→song 查表）。
  folder.updateSongs(
    uniqueItems(folder.songs, orderedItems(ids, mapsOf(reply.value))),
    folder.sortField,
  );
  folder.cursor += ids.length;
  if (selectAfter != null && selectAfter >= 0 && selectAfter < folder.songs.length) {
    await librarySelectDirectory(lib, selectAfter, 'archive');
  } else if (selectAfter != null &&
      selectAfter >= folder.songs.length &&
      folder.cursor < folder.ids.length) {
    // 大步滚动可能跨过多页，不能只补一页就丢弃待选目标。
    await libraryLoadDirectoryPage(lib, selectAfter);
  } else if (selectAfter != null && selectAfter >= 0 && folder.songs.isNotEmpty) {
    await librarySelectDirectory(lib, selectAfter % folder.songs.length, 'archive');
  } else {
    lib.changed();
  }
}
/// Qt MusicDirectory.cpp:379-398 MusicLibrary::showDirectoryInfo：
/// 目录资料页接管 current/tracks，并单独发音乐身份请求。
Future<void> libraryShowDirectoryInfo(MusicLibrary lib) async {
  final DirectoryFolder? folder = lib.directory;
  if (folder == null) {
    return;
  }
  lib.selectionGeneration++;
  lib.directoryInfo = true;
  lib.current = folder.item;
  if (!lib.isLocal) {
    // Qt: loadSubscriptionStatus(current)；根文件对应成员无参数（music_library.dart:2343）。
    unawaited(lib.loadSubscriptionStatus());
  }
  lib.detailLoading = false;
  // Qt 是 QJsonArray 值语义拷贝，避免后续目录内改写穿透到当前列表。
  lib.tracks = List<JsonMap>.from(folder.orderedSongs());
  lib.trackIds = List<Object?>.from(folder.ids);
  lib.coverImage = '';
  lib.coverKey = '';
  lib.identityRequests.add(textOf(folder.item['key']));
  unawaited(lib.loadCover(folder.item));
  lib.modeRequests.add('detail');
  lib.changed();
}

/// Qt MusicDirectory.cpp:401-415 MusicLibrary::returnToDirectory：
/// 只有目录资料页需要恢复歌曲选择；空目录直接退栈。
Future<void> libraryReturnToDirectory(MusicLibrary lib) async {
  final DirectoryFolder? folder = lib.directory;
  if (folder != null) {
    if (folder.songs.isEmpty) {
      await libraryLeaveDirectory(lib);
      return;
    }
    if (lib.directoryInfo) {
      await librarySelectDirectory(lib, folder.index, 'archive');
    } else {
      lib.wantsSongDetails = false;
      lib.modeRequests.add('archive');
    }
  }
  lib.changed();
}

/// Qt MusicDirectory.cpp:417-452 MusicLibrary::leaveDirectory：
/// restore 时按 parentPhysical/parentLane 复位，并沿父链返回；
/// 顶部无父目录时用列表栏名收尾（"已返回：" + columns[selectedLane]）。
Future<void> libraryLeaveDirectory(MusicLibrary lib, {bool restore = true}) async {
  final DirectoryFolder? folder = lib.directory;
  if (folder == null) {
    return;
  }
  lib.directoryGeneration++;
  lib.directory = restore ? folder.parent : null;
  lib.directoryLoading = false;
  lib.directoryInfo = false;
  lib.selectionGeneration++;
  lib.wikiGeneration++;
  lib.tracks = <JsonMap>[];
  lib.trackIds = <String>[];
  lib.coverImage = '';
  lib.coverKey = '';
  lib.detailLoading = false;
  if (restore) {
    lib.selectedLane = folder.parentLane;
    lib.selectedPhysical = folder.parentPhysical;
    lib.current = lib.details[textOf(folder.item['key'])] ?? folder.parentItem;
    lib.selectionRequests.add((
      index: folder.parentPhysical,
      navigation: <String, Object?>{'axis': 'lane', 'direction': -1},
    ));
    lib.modeRequests.add('archive');
    final DirectoryFolder? parent = lib.directory;
    if (parent != null) {
      await librarySelectDirectory(lib, parent.index, 'archive');
      lib.status = '已返回：' + textOf(parent.item['title']);
      lib.changed();
      return;
    }
    if (lib.current.isNotEmpty) {
      lib.identityRequests.add(textOf(lib.current['key']));
      unawaited(lib.loadCover(lib.current));
    }
  }
  lib.status = '已返回：' + directoryColumnValue(lib.columns, lib.selectedLane);
  lib.changed();
}

/// Qt MusicDirectory.cpp:455-503 MusicLibrary::followPlayback：
/// 队列外曲目先建"播放队列"目录（parent=当前目录），再按物理格位选中。
Future<void> libraryFollowPlayback(MusicLibrary lib, JsonMap value) async {
  // Qt MusicDirectory.cpp:456-457 是 QJsonValue 等值比较（类型敏感），
  // 故这里比较原始值而不是 textOf 归一化后的字符串。
  if (lib.current['key'] == value['key'] && lib.current['id'] == value['id']) {
    return;
  }
  final JsonMap previous = lib.current;
  final int physical = directoryResolvePhysical(lib);
  DirectoryFolder? node = lib.directory;
  int index = node == null ? -1 : indexOfId(node.orderedSongs(), textOf(value['id']));
  if (index < 0) {
    lib.directoryGeneration++;
    lib.directoryLoading = false;
    final List<JsonMap> queue = mapsOf(lib.player.queueItems);
    node = DirectoryFolder(
      parent: lib.directory,
      item: <String, Object?>{
        'kind': 'playlist',
        'key': 'playback:queue',
        'id': '',
        'title': '播放队列',
        'trackCount': lib.player.queueSize,
      },
      songs: List<JsonMap>.from(queue),
    );
    for (final JsonMap song in queue) {
      node.ids.add(itemIdOf(song));
    }
    node.cursor = lib.player.queueSize;
    index = lib.player.queueIndexOfId(textOf(value['id']));
    node.index = index;
    final int row = directoryLaneSlots(lib, lib.selectedLane).indexOf(physical);
    node.anchor = lib.selectedLane * 8 + (row < 0 ? 0 : row);
    node.parentPhysical = physical;
    node.parentLane = lib.selectedLane;
    node.parentItem = previous;
    lib.directory = node;
  }
  final DirectoryFolder folder = node!;
  if (index < 0 || index >= folder.songs.length) {
    return;
  }
  final List<JsonMap> songs = List<JsonMap>.from(folder.songs);
  final int rawIndex = indexOfId(songs, textOf(value['id']));
  if (rawIndex >= 0) {
    songs[rawIndex] = value;
  }
  folder.updateSongs(songs, folder.sortField);
  index = indexOfId(folder.orderedSongs(), textOf(value['id']));
  final int cell = (index + folder.anchor) % 40;
  final int target = directoryPhysicalOfCell(lib, cell);
  // Qt 在 selectDirectory 之后才写 frame["mode"]，保持同步发射顺序。
  unawaited(librarySelectDirectory(
    lib,
    index,
    'detail',
    axis: target == physical ? 'row' : '',
    direction: target == physical ? 8 : 1,
  ));
  if (lib.frame.isNotEmpty) {
    lib.frame['mode'] = 'detail';
  }
}
