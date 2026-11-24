/// 塞壬唱片基本版的冻结数据契约（Qt → Flutter 迁移）。
///
/// 本文件是跨 lane 契约 v1 的唯一写者；改名必须先通知其他 lane。
/// 对应实现（只读）：
/// - MusicBridge/client/siren.mjs
///   songItem :189-216、albumItem :218-255、detail :414-439、playback :482-495、lyrics :497-513
/// - Qt/src/MusicSiren.cpp
///   曲库读取 :46-88、本地搜索匹配字段 :105-124、文案 :50/:63/:78-79/:181-183
/// - MusicBridge/lyrics-format.cjs
///   parseLrc :35-53、normalizeLyrics :128-213（LRC 行/翻译/偏移规则）
library;

/// 塞壬唱片 provider 名（siren.mjs:199 的 provider: 'siren'）。
const String sirenProvider = 'siren';

/// 上游条目标题为空时的占位文案（siren.mjs:203、:242 的 '正在读取…'）。
const String sirenUnknownTitle = '正在读取…';

/// 上游未给出艺人时的默认艺人（siren.mjs:13 的 DEFAULT_ARTIST）。
const String sirenDefaultArtist = '塞壬唱片-MSR';

/// 歌词文本长度上限（MusicBridge/client/siren.mjs:497-513 的 1000000 字符）。
const int sirenMaxLyricLength = 1000000;

/// 塞壬唱片曲库中的一首歌（siren.mjs songItem :189-216）。
///
/// 曲库阶段 [sourceUrl]、[lyricUrl] 为空、[durationMs] 为 0：上游 /api/songs 不提供它们
/// （siren.mjs:198-215 没有 sourceUrl/lyricUrl，duration 固定 0），播放前必须 fresh 请求
/// /api/song/<id> 拿到带时效签名的直链（siren.mjs:293-296）；真实时长来自 native 回报。
class SirenSong {
  const SirenSong({
    required this.id,
    required this.title,
    required this.artist,
    required this.album,
    required this.albumId,
    required this.cover,
    required this.sourceUrl,
    required this.lyricUrl,
    required this.durationMs,
  });

  /// 上游 cid（siren.mjs:190 trimmed）。
  final String id;

  /// 标题；空则上游占位文案（siren.mjs:203）。
  final String title;

  /// 艺人名以 ' / ' 连接（siren.mjs:204）。
  final String artist;

  /// 所属专辑名（siren.mjs:208 取 catalog.albumByID[albumCid].name）。
  final String album;

  /// 所属专辑 cid（siren.mjs:194）。
  final String albumId;

  /// 专辑封面地址（siren.mjs:209）。
  final String cover;

  /// 播放直链：曲库阶段为空，播放前 fresh 读取（siren.mjs:293-296）。
  final String sourceUrl;

  /// 歌词地址：曲库阶段为空，详情接口返回（siren.mjs:497-513）。
  final String lyricUrl;

  /// 时长（毫秒）：曲库阶段为 0（siren.mjs:213），播放中由 native 回报覆盖。
  final double durationMs;

  /// 曲目键（siren.mjs:202 的 'siren:song:' + id）。
  String get key => 'siren:song:$id';

  /// 有可播放直链。
  bool get playable => sourceUrl.isNotEmpty;

  SirenSong copyWith({
    String? title,
    String? artist,
    String? album,
    String? albumId,
    String? cover,
    String? sourceUrl,
    String? lyricUrl,
    double? durationMs,
  }) {
    return SirenSong(
      id: id,
      title: title ?? this.title,
      artist: artist ?? this.artist,
      album: album ?? this.album,
      albumId: albumId ?? this.albumId,
      cover: cover ?? this.cover,
      sourceUrl: sourceUrl ?? this.sourceUrl,
      lyricUrl: lyricUrl ?? this.lyricUrl,
      durationMs: durationMs ?? this.durationMs,
    );
  }

  /// MusicPlayer / PlaybackQueue 认的曲目形状（lib/domain/player/music_player.dart:350-383
  /// 只校验 kind 与 provider；lib/domain/player/playback_queue.dart:63-85 用 provider:id 做身份）。
  Map<String, Object?> toTrack() {
    return <String, Object?>{
      'provider': sirenProvider,
      'kind': 'song',
      'id': id,
      'key': key,
      'title': title,
      'artist': artist,
      'album': album,
      'albumID': albumId,
      'cover': cover,
      'sourceUrl': sourceUrl,
      'duration': durationMs,
    };
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) {
      return true;
    }
    return other is SirenSong &&
        other.id == id &&
        other.title == title &&
        other.artist == artist &&
        other.album == album &&
        other.albumId == albumId &&
        other.cover == cover &&
        other.sourceUrl == sourceUrl &&
        other.lyricUrl == lyricUrl &&
        other.durationMs == durationMs;
  }

  @override
  int get hashCode => Object.hash(
    id,
    title,
    artist,
    album,
    albumId,
    cover,
    sourceUrl,
    lyricUrl,
    durationMs,
  );

  @override
  String toString() => 'SirenSong($id, $title)';
}

/// 塞壬唱片曲库中的一张专辑（siren.mjs albumItem :218-255）。
class SirenAlbum {
  const SirenAlbum({
    required this.id,
    required this.name,
    required this.artist,
    required this.cover,
    required this.songCount,
    required this.songs,
  });

  /// 上游 cid（siren.mjs:219 trimmed）。
  final String id;

  /// 专辑名；空则上游占位文案（siren.mjs:242）。
  final String name;

  /// 艺人名以 ' / ' 连接（siren.mjs:243）。
  final String artist;

  /// 封面地址（siren.mjs:248）。
  final String cover;

  /// 曲目数：曲库阶段 = albumSongs 数（siren.mjs:253）；专辑详情后 = detail.songs 数（:430）。
  final int songCount;

  /// 曲目列表：曲库阶段来自 /api/songs 的 albumCid 归组（siren.mjs:313 的 albumSongs），
  /// 专辑详情后用 /api/album/<id>/detail 的 songs 覆盖（siren.mjs:426-428）。
  final List<SirenSong> songs;

  /// 专辑键（siren.mjs:241 的 'siren:album:' + id）。
  String get key => 'siren:album:$id';

  SirenAlbum copyWith({
    String? name,
    String? artist,
    String? cover,
    int? songCount,
    List<SirenSong>? songs,
  }) {
    return SirenAlbum(
      id: id,
      name: name ?? this.name,
      artist: artist ?? this.artist,
      cover: cover ?? this.cover,
      songCount: songCount ?? this.songCount,
      songs: songs ?? this.songs,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) {
      return true;
    }
    return other is SirenAlbum &&
        other.id == id &&
        other.name == name &&
        other.artist == artist &&
        other.cover == cover &&
        other.songCount == songCount;
  }

  @override
  int get hashCode => Object.hash(id, name, artist, cover, songCount);

  @override
  String toString() => 'SirenAlbum($id, $name)';
}

/// /api/song/<id> 的即时详情（siren.mjs:282-296、:482-495、:497-513）。
///
/// 只保留播放与歌词需要的两个带时效字段，外加标题；不做本地缓存——
/// 直链带时效签名，必须每次播放前 fresh 读取（siren.mjs:293 的注释）。
class SirenSongDetail {
  const SirenSongDetail({
    required this.id,
    required this.title,
    required this.sourceUrl,
    required this.lyricUrl,
  });

  final String id;
  final String title;
  final String sourceUrl;
  final String lyricUrl;

  @override
  String toString() => 'SirenSongDetail($id, playable: $playable)';

  bool get playable => sourceUrl.isNotEmpty;
}

/// /api/songs + /api/albums 的一次性全量曲库（siren.mjs:310-316）。
class SirenCatalog {
  const SirenCatalog({required this.songs, required this.albums});

  final List<SirenSong> songs;
  final List<SirenAlbum> albums;
}

/// 一个已打开的塞壬虚拟目录（Qt/src/MusicLibrary.h:12-34 的 MusicDirectory 收窄投影）。
///
/// 基本版只有一个目录：Qt/src/MusicSiren.cpp:193-246 的 openSirenAllSongs 构造的
/// “全部歌曲”（provider=siren / kind=playlist / virtual / id=siren-all /
/// key=siren:playlist:all）。字段逐条对应 Qt 的 MusicDirectory 成员：
/// [songs]/[ids]/[cursor] 是目录自己的曲目、完整 ID 顺序与已加载游标（Qt :220-223），
/// [index] 是目录内的选中行（Qt MusicDirectory::index：selectDirectory 写、leaveDirectory 读回），
/// [parent] 是上一级目录（null = 资料库根，Qt :206）。
class BasicDirectory {
  const BasicDirectory({
    required this.provider,
    required this.kind,
    required this.id,
    required this.key,
    required this.title,
    required this.artist,
    required this.cover,
    required this.description,
    required this.trackCount,
    required this.songs,
    required this.ids,
    required this.cursor,
    required this.index,
    this.anchor = 0,
    this.virtual = true,
    this.parent,
    this.parentLane = basicDefaultLane,
    this.parentSelection,
  });

  /// Qt item.provider（'siren'）。
  final String provider;

  /// Qt item.kind（siren 目录固定 'playlist'）。
  final String kind;

  /// Qt item.id（'siren-all'）。
  final String id;

  /// Qt item.key（'siren:playlist:all'）。
  final String key;

  /// Qt item.title（'全部歌曲'）；目录内资料库标题显示它（Qt libraryName()）。
  final String title;

  /// Qt item.artist（providerName()，siren = '塞壬唱片'）。
  final String artist;

  /// Qt item.cover（目录首曲封面；基础版没有图片管线，只带身份）。
  final String cover;

  /// Qt item.description（'塞壬唱片全部歌曲'）。
  final String description;

  /// Qt item.trackCount（目录曲目数）。
  final int trackCount;

  /// Qt item.virtual（虚拟目录标志）。
  final bool virtual;

  /// Qt directory->songs：目录曲目（顺序就是列表顺序）。
  final List<SirenSong> songs;

  /// Qt directory->ids：完整 ID 顺序（可多于 [songs]；基础版不做增量补全）。
  final List<String> ids;

  /// Qt directory->cursor：ids 中已落到 [songs] 的条数。
  final int cursor;

  /// Qt MusicDirectory::index：目录内选中行（位置真值，不是身份）。
  final int index;

  /// Qt MusicDirectory::anchor（0..39）：目录窗口的锚点。
  ///
  /// Qt 用 `cell = (index + anchor) % 40` 把目录行折进 5 列 × 8 行的逻辑格，再用
  /// `selectedLane = cell / 8` 决定高亮在哪一列（Qt/src/MusicDirectory.cpp:302-319
  /// selectDirectory）；`updateSongs` 还用它算 page（同文件 :21-31）。
  ///
  /// 打开目录时 Qt 就写好它：`destination = (selectedLane + 1) % 5;
  /// next->anchor = destination * 8 + rowMemory[destination]`
  /// （Qt/src/MusicDirectory.cpp:50-90 enterDirectory / Qt/src/MusicSiren.cpp:229-240
  /// openSirenAllSongs），但 open 本身**不调** selectDirectory，所以首帧列号仍是打开前
  /// 那一列；之后 ±8/选中才按 anchor 折列。基础版没有 physicalSlots，所以这里只持有
  /// 逻辑锚点：它**不是**物理记录下标或物理槽位。
  final int anchor;

  /// Qt MusicDirectory::page：当前 40 条窗口起点（Qt/src/MusicDirectory.cpp:308）。
  int get page => index ~/ 40 * 40;

  /// 目录行 [index] 折进 Qt 40 格窗口后的**逻辑格**（0..39，不是物理槽）。
  int cellAt(int index) => ((index + anchor) % 40 + 40) % 40;

  /// 目录行 [index] 落在哪一列（Qt `selectedLane = cell / 8`）。
  int laneAt(int index) => cellAt(index) ~/ 8;

  /// 上一级目录（null = 资料库根）。
  final BasicDirectory? parent;

  /// 退出目录后回到的资料库列（Qt/src/MusicDirectory.cpp:417-452 `leaveDirectory(true)`
  /// 的 `parentLane`：Qt 退出目录会恢复打开前的那一列，不会把用户丢到 lane 0）。
  final int parentLane;

  /// 退出目录后恢复的选中身份（Qt `parentItem` 的 kind + id 投影）。
  final BasicSelection? parentSelection;

  /// 复制并改选中行/游标/曲目/锚点（Qt 直接改 MusicDirectory 的可变字段）。
  BasicDirectory copyWith({
    List<SirenSong>? songs,
    List<String>? ids,
    int? cursor,
    int? trackCount,
    int? index,
    int? anchor,
  }) {
    return BasicDirectory(
      provider: provider,
      kind: kind,
      id: id,
      key: key,
      title: title,
      artist: artist,
      cover: cover,
      description: description,
      trackCount: trackCount ?? this.trackCount,
      songs: songs ?? this.songs,
      ids: ids ?? this.ids,
      cursor: cursor ?? this.cursor,
      index: index ?? this.index,
      anchor: anchor ?? this.anchor,
      virtual: virtual,
      parent: parent,
      parentLane: parentLane,
      parentSelection: parentSelection,
    );
  }

  @override
  String toString() => 'BasicDirectory($id, $title, $index/${songs.length})';
}

/// 可显示的塞壬唱片错误（文案与 siren.mjs 的 Error 一致，不另起一套）。
class SirenException implements Exception {
  const SirenException(this.message, [this.cause]);

  /// 可直接上屏的中文文案（siren.mjs:68/:101/:105 的原文模板）。
  final String message;

  /// 原始异常（HttpException / FormatException 等），用于诊断，不上屏。
  final Object? cause;

  @override
  String toString() => message;
}

/// 一句歌词（LRC 的一行；translation 来自行尾【…】）。
class BasicLyricLine {
  const BasicLyricLine({
    required this.startMs,
    required this.text,
    this.translation = '',
  });

  /// 行起始毫秒（MusicBridge/lyrics-format.cjs:35-53 的 startMs）。
  final double startMs;

  final String text;

  /// 翻译（可为空；Qt 侧同样只对【…】后缀拆分）。
  final String translation;

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) {
      return true;
    }
    return other is BasicLyricLine &&
        other.startMs == startMs &&
        other.text == text &&
        other.translation == translation;
  }

  @override
  int get hashCode => Object.hash(startMs, text, translation);

  @override
  String toString() => 'BasicLyricLine($startMs, $text)';
}

/// 解析后的歌词文档（对齐 lyrics-format.cjs normalizeLyrics :128-213）。
class BasicLyricsDocument {
  const BasicLyricsDocument({
    required this.lines,
    required this.offsetMs,
    required this.plainText,
    required this.timed,
  });

  static const BasicLyricsDocument empty = BasicLyricsDocument(
    lines: <BasicLyricLine>[],
    offsetMs: 0,
    plainText: '',
    timed: false,
  );

  final List<BasicLyricLine> lines;

  /// 文档级偏移（LRC [offset:…] 标签，夹到 ±10000；lyrics-format.cjs:202-212）。
  final double offsetMs;

  /// 无时间轴时的纯文本（timing: 'none'）。
  final String plainText;

  /// 是否有时间轴（lines 非空）。
  final bool timed;

  bool get isEmpty => lines.isEmpty && plainText.trim().isEmpty;

  /// 转成 LyricsController.accept 认的文档形状
  /// （lib/domain/lyrics/lyrics_controller.dart:219-228 + lib/domain/lyrics/lyrics_timeline.dart
  /// 的 validLyricsDocument：version 1、timing line/none、lines ≤ 5000、offsetMs 数值）。
  Map<String, Object?> toLyricsDocument({String source = 'siren'}) {
    return <String, Object?>{
      'version': 1,
      'source': source,
      'timing': timed ? 'line' : 'none',
      'offsetMs': offsetMs,
      'lines': <Object?>[
        for (final BasicLyricLine line in lines)
          <String, Object?>{
            'startMs': line.startMs,
            'text': line.text,
            'translation': line.translation,
            'words': const <Object?>[],
          },
      ],
      'plainText': plainText,
    };
  }
}

/// 基础版的一级页面（Qt MusicSiren 的 archive/lanes 收窄成一个库页 + 详情 + 歌词）。
enum BasicPhase { boot, library, detail, lyrics }

/// 塞壬唱片的资料库**五列**（Qt/src/MusicLibrary.cpp:26-27 构造里的 columns，逐字）：
/// `{"搜索结果", "喜欢的歌曲", "我的歌单", "全部歌曲", "全部专辑"}`。
///
/// Qt 的 source/column 是资料库的列，**不是 provider**：单个 Siren 平台也有这五列，
/// ←/→ 在列之间循环（Qt/src/MusicLibrary.cpp:184-186 sourceOrder()）。
const List<String> basicSirenColumns = <String>[
  '搜索结果',
  '喜欢的歌曲',
  '我的歌单',
  '全部歌曲',
  '全部专辑',
];

/// Qt MusicLibrary::sourceOrder()（Qt/src/MusicLibrary.cpp:184-186）：
/// Siren = `{1,2,3,4,0}`（kugou 是四列 `{1,2,3,0}`，基础版只接 Siren）。
const List<int> basicSirenSourceOrder = <int>[1, 2, 3, 4, 0];

/// 「搜索结果」列（Qt 的 lane 0）。
const int basicSearchLane = 0;

/// 首屏列：Qt 是 0（MusicLibrary.h:167 `selectedLane = 0`，再由 MusicSession.cpp:93-138
/// 用会话恢复）；基础版没有会话持久化，而 lane 0 在空关键词下诚实为空，所以首屏落在
/// **全部歌曲**（lane 3）。这只是初始列的选择：列名、顺序、循环仍是 Qt 的那一套。
const int basicDefaultLane = 3;

/// 列名（越界回空串；Qt MusicLibrary::libraryName() 的 `columns.value(lane)` 分支，
/// Qt/src/MusicLibrary.cpp:188-193）。
String basicLaneName(int lane, {List<String> columns = basicSirenColumns}) =>
    lane >= 0 && lane < columns.length ? columns[lane] : '';

/// 列在 sourceOrder 里的序号（界面 `COLLECTION xx / 05` 的 xx-1：
/// Qt/src/NativeHud.cpp:479 `sourceOrder().indexOf(selectedLane)`）。
int basicSourceOrderIndex(int lane) {
  final int index = basicSirenSourceOrder.indexOf(lane);
  return index < 0 ? 0 : index;
}

/// ←/→ 的下一列：Qt `wrap(index ± 1, sources.size())`（Qt/src/NativeHudController.cpp:658-662）。
int basicStepSourceLane(int lane, int direction) {
  final int count = basicSirenSourceOrder.length;
  final int step = direction >= 0 ? 1 : -1;
  return basicSirenSourceOrder[(basicSourceOrderIndex(lane) + step + count) %
      count];
}

/// 空列上屏的诚实空态：不编数据、不假装本机集合已经接上。
///
/// lane 1「喜欢的歌曲」/ lane 2「我的歌单」是**本机**集合，不是账号数据：Qt 给 Siren
/// 构造的是 `LocalCollections`（Qt/src/MusicLibrary.cpp:26-30），`reloadSirenCollections`
/// 只读 `likedIDs()` 与 `playlists()`（Qt/src/MusicSiren.cpp:6-21），没有任何登录条件。
///
/// [localCollectionsAvailable] 是“这一个基础版进程真的拿到本机集合端口了吗”：
/// false（当前生产事实）时只声明暂不可用——不能把“没查询过”说成“空库”，更不能说成
/// “账号数据”；只有端口真的注入并查询过、结果确实为空，才上屏 Qt 的空态文案
/// （Qt/src/MusicSiren.cpp:265/:283 '暂无喜欢的歌曲' / '暂无本地歌单…'）。
///
/// [unresolvedLikedIds] 是“源集合非空、但曲库还解析不出这些 id”的条数（端口刚注入、
/// 曲库还没加载完时就是全部）。这种情况**不是空收藏**：Qt loadSirenSource 会拿 id 去
/// 请求 songs 再补行（Qt/src/MusicSiren.cpp:296-322），所以这里只诚实声明“还没对上曲库”，
/// 既不造 `SirenSong`、也不上屏 '暂无喜欢的歌曲'。
String basicLaneEmptyNotice(
  int lane, {
  bool localCollectionsAvailable = false,
  int unresolvedLikedIds = 0,
  bool remote = false,
}) {
  // 插件平台：收藏与歌单来自服务端（`likedIDs` / `userPlaylists`），本机集合端口
  // 是否存在与这里无关；未登录时 Qt 上屏的是「请登录」+ 平台名。
  if (remote) {
    switch (lane) {
      case basicSearchLane:
        return '输入关键词检索音乐';
      case 1:
        return '暂无喜欢的歌曲';
      case 2:
        return '暂无歌单';
      case 3:
        return '来源曲库为空';
      case 4:
        return '暂无收藏专辑';
    }
  }
  switch (lane) {
    case basicSearchLane:
      return '输入关键词检索塞壬唱片曲库';
    case 1:
      if (!localCollectionsAvailable) {
        return '本地集合暂不可用：还没接上本机收藏';
      }
      if (unresolvedLikedIds > 0) {
        return '本地收藏有 $unresolvedLikedIds 首还没对上曲库，稍后重试';
      }
      return '暂无喜欢的歌曲';
    case 2:
      return localCollectionsAvailable ? '暂无本地歌单' : '本地集合暂不可用：还没接上本机歌单';
    case 3:
      return '塞壬唱片曲库为空';
    case 4:
      return '塞壬唱片还没有专辑';
    default:
      return '这一列没有内容';
  }
}

/// 插件平台的 `artist` 串常带尾随分隔符或孤立顿号（真机 `洛天依 / 阑阗 / 、薛钦`），
/// 统一整理成「A / B / C」再显示与拼底注。
String basicCleanArtist(String raw) {
  // 插件回来的串里常混着零宽空格（U+200B）与不换行空格（U+00A0），`trim()` 不认它们，
  // 于是段首的「、」被零宽字符挡住、剥不掉（真机仍显示「、薛钦」）。
  const String junk = '、,，·;；\u200B\uFEFF\u00A0\u3000';
  final List<String> parts = <String>[];
  for (final String chunk in raw.split('/')) {
    String name = chunk.replaceAll(RegExp('[\u200B\uFEFF\u00A0]'), ' ').trim();
    // 两端都要剥：既可能是「、薛钦」，也可能是「薛钦、」。
    bool changed = true;
    while (changed && name.isNotEmpty) {
      changed = false;
      if (junk.contains(name[0])) {
        name = name.substring(1).trim();
        changed = true;
      }
      if (name.isNotEmpty && junk.contains(name[name.length - 1])) {
        name = name.substring(0, name.length - 1).trim();
        changed = true;
      }
    }
    if (name.isNotEmpty && RegExp(r'[^\s、,，·;；]').hasMatch(name)) {
      parts.add(name);
    }
  }
  return parts.join(' / ');
}

/// 列表里“被选中”的那一项（Qt `music.current` 的单值投影：kind + id）。
///
/// 选中与播放是**两件事**：Qt 的 archive 列表只维护 current/selectedPhysical
/// （Qt/src/MusicDirectory.cpp:302-319 `selectDirectory` 不发 play），播放身份是
/// MusicPlayer 的 current。这里同理：[BasicViewState.song] 是选中曲目，
/// [BasicViewState.playingTrack] 是真正的播放曲目，两者不得互相顶替。
class BasicSelection {
  const BasicSelection({required this.kind, required this.id});

  /// 'song' 或 'album'（与列表行的 kind 同一词表）。
  final String kind;

  /// 源条目 id（[BasicViewState.songs] / [BasicViewState.albums] 里的 id）。
  final String id;

  bool get isSong => kind == 'song';

  @override
  bool operator ==(Object other) =>
      other is BasicSelection && other.kind == kind && other.id == id;

  @override
  int get hashCode => Object.hash(kind, id);

  @override
  String toString() => 'BasicSelection($kind:$id)';
}

/// 本机集合的**只读**查询端口：Qt `LocalCollections`（Qt/src/MusicLibrary.cpp:26-30）
/// 里 Siren 列真正读到的两项——`likedIDs()` 与 `playlists()`
/// （Qt/src/MusicSiren.cpp:6-21 reloadSirenCollections）。
///
/// 这是查询接口，不是第二份曲库/播放器/持久化：行数据仍由 Flutter 曲库投影
/// （喜欢过的 id → 现有曲库的曲目；歌单 → [BasicLocalPlaylist] 行），基础版也没有
/// 收藏/歌单的写入口（编辑 UI 不在本次范围）。生产侧目前没有任何实现曾被注入
/// （`BasicController(collections:)` 默认 null），所以 [BasicViewState.localCollectionsAvailable]
/// 为 false 是事实，不是“空库”。
abstract class BasicLocalCollections {
  /// 本机喜欢过的曲目 id（按本机顺序；Qt `likedIDs()` 的字符串列表投影）。
  List<String> likedIds();

  /// 本机歌单（Qt `collections->playlists()` 的 id/title/trackCount 投影）。
  List<BasicLocalPlaylist> playlists();
}

/// 本机歌单的一行（Qt `playlists()` 的 id/title/trackCount）。
///
/// 基础版只展示（列表行 + 身份），不提供新建/改名/删除/加曲。
class BasicLocalPlaylist {
  const BasicLocalPlaylist({
    required this.id,
    required this.title,
    this.trackCount = 0,
  });

  /// 本机歌单 id（Qt `playlists()` 的 id）。
  final String id;

  /// 上屏标题（Qt `playlists()` 的 title）。
  final String title;

  /// 曲目数（Qt `playlists()` 的 trackCount）。
  final int trackCount;

  @override
  bool operator ==(Object other) =>
      other is BasicLocalPlaylist &&
      other.id == id &&
      other.title == title &&
      other.trackCount == trackCount;

  @override
  int get hashCode => Object.hash(id, title, trackCount);

  @override
  String toString() => 'BasicLocalPlaylist($id:$title/$trackCount)';
}

/// 界面只读的状态快照；唯一写者是 BasicController。
///
/// 冻结契约要求的 getter（phase/loading/error/status/query/songs/albums/album/song/playing/
/// buffering/positionMs/durationMs/playbackError/lyrics/lyricIndex/dark）在这里都是 final 字段，
/// 读取方式与 getter 完全一致；其余字段是 追加的空态/播放辅助信息。
class BasicViewState {
  const BasicViewState({
    this.phase = BasicPhase.boot,
    this.loading = false,
    this.error = '',
    this.status = '',
    this.query = '',
    this.songs = const <SirenSong>[],
    this.albums = const <SirenAlbum>[],
    this.album,
    this.directory,
    this.song,
    this.playing = false,
    this.buffering = false,
    this.positionMs = 0,
    this.durationMs = 0,
    this.playbackError = '',
    this.lyrics = const <BasicLyricLine>[],
    this.lyricIndex = -1,
    this.lyricsPreviewId = '',
    this.dark = false,
    this.queue = const <SirenSong>[],
    this.queueIndex = -1,
    this.queueMode = 'all',
    this.searchKind = 'song',
    this.searchGroup = 'none',
    this.searchGroupKey = '',
    this.searchRemote = false,
    this.searchRows = const <Map<String, Object?>>[],
    this.searchTotal = 0,
    this.searchStatus = '',
    this.searchGroups = const <String, List<int>>{},
    this.lyricStatus = 'idle',
    this.lyricsOffsetMs = 0,
    this.lyricsGlobalOffsetMs = 0,
    this.lyricMessage = '',
    this.playerStatus = '',
    this.catalogLoaded = false,
    this.selection,
    this.playingTrack,
    this.listPosition,
    this.songWiki = '',
    this.songWikiLoading = false,
    this.selectedLane = basicDefaultLane,
    this.localCollectionsAvailable = false,
    this.localUnresolvedLikedIds = 0,
    this.localPlaylists = const <BasicLocalPlaylist>[],
    this.serverPlaylists = const <BasicLocalPlaylist>[],
    this.laneColumns = basicSirenColumns,
    this.laneItems = const <List<BasicListItem>>[],
    this.laneOffsets = const <int>[],
  });

  /// 当前页面。
  final BasicPhase phase;

  /// 曲库/详情读取中（播放器的 loading 见 playerStatus）。
  final bool loading;

  /// 曲库或详情读取失败的可显示文案（空串 = 无错误）。
  final String error;

  /// 导航/曲库状态文案（Qt MusicSiren 的 status 同义；播放器状态见 playerStatus）。
  final String status;

  /// 搜索词（空串 = 未过滤）。
  final String query;

  /// 当前可见歌曲列表（query 非空时是过滤结果）。
  final List<SirenSong> songs;

  /// 当前可见专辑列表（query 非空时是过滤结果）。
  final List<SirenAlbum> albums;

  /// 打开的专辑详情（phase == detail 且从专辑进入时非空）。
  final SirenAlbum? album;

  /// 已打开的虚拟目录（null = 资料库根；Qt MusicLibrary 的 directory 同义）。
  ///
  /// 目录打开时列表只放目录曲目（Qt MusicLibrary.cpp:212-214 的
  /// `directory ? directory->orderedSongs() : …`），[albums] 为空。
  final BasicDirectory? directory;

  /// 当前**选中**的曲目（浏览/选中/详情页都看它）：只由列表选中写入。
  ///
  /// 它不是播放身份——真正在播的是 [playingTrack]（MusicPlayer 的 current）；歌词页与
  /// 播放条都以 [playingTrack] 为准，浏览/换列不改播放，播放器换曲也不改这里。
  final SirenSong? song;

  final bool playing;
  final bool buffering;

  /// 播放位置（毫秒，只来自 native 回报的 BasicAudioState.positionMs）。
  final double positionMs;

  /// 时长（毫秒，只来自 native 回报）。
  final double durationMs;

  /// 播放失败文案（MusicPlayer.fail 的 status；空串 = 无失败）。
  final String playbackError;

  /// 当前曲目的歌词行（无歌词/未加载为空）。
  final List<BasicLyricLine> lyrics;

  /// 歌词面板当前承载的是哪首曲目（空串 = 跟随正在播放的那首）。
  ///
  /// 用户要求「歌词无需播放就能看」：详情页停在未播放的曲目上时，歌词面板
  /// 展示的是**选中曲目**的歌词，播放进度/高亮行不参与（没有在播就没有进度）。
  /// 用 id 而不是 bool，是因为歌词文本与曲目必须同源——切换选中行后旧的
  /// 歌词不许继续挂在新的标题下面。
  final String lyricsPreviewId;

  /// 活动行下标（-1 = 未到第一行或没有时间轴）。
  final int lyricIndex;

  /// 深色模式（基础版固定跟随构造参数，不做主题切换）。
  final bool dark;

  /// 播放队列（与 MusicPlayer.queue 同步的只读投影）。
  final List<SirenSong> queue;

  /// 队列中当前行（-1 = 空队列）。
  final int queueIndex;

  /// 播放模式（'off' / 'all' / 'one' / 'shuffle'，对齐 MusicPlayer.mode）。
  final String queueMode;

  /// 当前检索分类（`song` / `album` / `playlist` / `artist`，Qt `searchKind`）。
  final String searchKind;

  /// 当前分组键（`none` / `artist` / `album`，Qt `groupBy`）。
  final String searchGroup;

  /// 已展开的分组标题（空串 = 未展开；Qt `groupView` 的键）。
  final String searchGroupKey;

  /// 分类检索的命中行（Qt `MusicData::item` 形状的 Map），已按分组视图过滤。
  /// 检索结果是否来自远端（插件平台）。行点击要换成 `music:search-open:<i>`，
  /// 因为远端行不在本地 lane 里，`music:index:<i>` 会指到塞壬曲库。
  final bool searchRemote;

  final List<Map<String, Object?>> searchRows;

  /// 分类检索的命中总数（`INDEX / <total>`）。
  final int searchTotal;

  /// 分类检索的状态串（没有匹配的音乐 / 没有匹配的本地歌单 / 找到 N 条结果）。
  final String searchStatus;

  /// 分组名 → 该组在完整结果里的行下标（仅曲目分类 + 分组态非空）。
  final Map<String, List<int>> searchGroups;

  /// 歌词状态：'idle' / 'ready' / 'plain' / 'empty'（对齐 LyricsController.status 词表）。
  final String lyricStatus;

  /// 当前曲目的歌词偏移（毫秒，`LyricsController::offsetMs`）。
  /// 「歌词偏移」浮层要显示「已提前/已延后 N.Ns」，所以偏移值必须进视图状态，
  /// 不能让画布自己猜。
  final double lyricsOffsetMs;

  /// 全局歌词偏移（毫秒，`LyricsController::globalOffsetMs`）：
  /// 与当前偏移相等时浮层的「全局应用」只画灰字。
  final double lyricsGlobalOffsetMs;

  /// 歌词空态/加载态文案（LyricsController.message）。
  final String lyricMessage;

  /// 播放器状态文案（MusicPlayer.status 原文，如 '正在准备：…' / '正在播放：…'）。
  final String playerStatus;

  /// 曲库是否已成功加载过（失败重试/搜索空态判断用）。
  final bool catalogLoaded;

  /// 列表选中身份（Qt `music.current`）；null = 还没选过，按 [song]/[album] 回退。
  final BasicSelection? selection;

  /// 真正的播放曲目（来自 MusicPlayer 的 current）；null = 播放器没有 loaded 曲目。
  ///
  /// 与 [song]（选中）严格分开：浏览/选曲不改它，播放器换曲也不改 [song]。
  final SirenSong? playingTrack;

  /// 曲目列的滚动位置，单位是**条目**（小数 = 两项之间），Qt 的 ruler 同义
  /// （Qt/src/NativeHud.cpp:509 的 titleY + TrackRuler 的连续 position）。
  ///
  /// null = 没有独立的窗口位置，窗口跟随选中行（旧行为）；controller 每次都写绝对值。
  final double? listPosition;

  /// 当前详情曲目的百科正文（插件平台 `/wiki` 回执；塞壬平台恒空）。
  final String songWiki;

  /// 百科正在读取（Qt `detailLoading`：正文空时页面显示「正在读取歌曲百科…」）。
  final bool songWikiLoading;

  /// 当前资料库列（0..4，列名见 [basicSirenColumns]；Qt `MusicLibrary::selectedLane`）。
  ///
  /// 根页列表只承载这一列（Qt/src/MusicLibrary.cpp:195-207 sourceItems(lane)），
  /// ←/→ 按 [basicSirenSourceOrder] 循环换列。
  final int selectedLane;

  /// 本进程是否真的拿到了本机集合端口并查询过（Qt 的 `collections != nullptr` 同义）。
  ///
  /// false 时 lane 1/2 只声明「本地集合暂不可用」——不是空库，也不是平台前置条件缺失；
  /// true 时空才是 Qt 的真空态（Qt/src/MusicSiren.cpp:265/:283）。
  final bool localCollectionsAvailable;

  /// 源集合里已有、但当前曲库还解析不出的本机收藏条数（Qt 会拿这些 id 再补 songs）。
  ///
  /// 它让“源集合非空但暂时一首都显示不出来”与“源集合真的空”说出两句话：
  /// 前者见 [basicLaneEmptyNotice] 的 `unresolvedLikedIds` 分支，后者才是 '暂无喜欢的歌曲'。
  final int localUnresolvedLikedIds;

  /// 「我的歌单」列的行投影（本机 `playlists()`；不可用时为空）。
  ///
  /// 「喜欢的歌曲」的行不在这里：它们经 Flutter 曲库解析后进 [songs]
  /// （与 [selectedLane] 的投影同一份真值），见 [basicLibraryItems] 的 lane 1 分支。
  final List<BasicLocalPlaylist> localPlaylists;

  /// 插件平台的服务端歌单（Qt lane 2 的 lists[2] 在插件平台下来自 `userPlaylists(uid)`）。
  final List<BasicLocalPlaylist> serverPlaylists;

  /// 当前平台的列名（Qt `ProviderRegistry::columns(provider)`；塞壬/本地是
  /// [basicSirenColumns]，插件平台来自 manifest 的 `library.columns`）。
  ///
  /// 只影响文案与顺序，不影响行内容：行内容仍由 [basicLibraryItems] 按 lane 投影。
  final List<String> laneColumns;

  /// 列名（越界回空串，Qt `MusicLibrary::libraryName()`）。
  String laneName(int lane) =>
      lane >= 0 && lane < laneColumns.length ? laneColumns[lane] : '';

  /// 五列的条目投影（0..4 = [basicSirenColumns] 的顺序），给 Qt 的 40 格语义槽位用。
  ///
  /// 这是**同一份** [basicLibraryItems] 真值的按列展开，不是第二套业务状态：
  /// Qt 侧继续用自己的 m_columns/physicalSlots 几何，只是把 5×8 个物理格的
  /// `kind + id` 与这里的条目对上（槽位→条目的对应在 qt_scene_view 里做）。
  /// 空/越界的位置在投影里就是空槽，不造占位、不把 logical%40 冒充物理格。
  ///
  /// 默认空表 = 没有语义表（旧构造点/HUD 测试不需要知道这一层）。
  final List<List<BasicListItem>> laneItems;

  /// 五列窗口起点（Qt `offsets[lane]` 同义，单位条目，**可以是负数**）。
  ///
  /// 与 [laneItems] 一起构成有界的 8 行窗口：物理行 r 的条目 = laneOffsets[lane] + r。
  /// 负数/超出末尾的位置键为 Qt 的 wrap 语义保留（Qt src/MusicLibrary.cpp:646-667）。
  final List<int> laneOffsets;

  bool get hasCatalog => catalogLoaded;

  bool get canPlay => song != null;

  bool get showsLyrics => phase == BasicPhase.lyrics;

  /// 播放进度比例（0..1；未知时长时为 0，不造进度）。
  double get progressFraction {
    if (durationMs <= 0) {
      return 0;
    }
    return (positionMs / durationMs).clamp(0.0, 1.0).toDouble();
  }

  BasicViewState copyWith({
    BasicPhase? phase,
    bool? loading,
    String? error,
    String? status,
    String? query,
    List<SirenSong>? songs,
    List<SirenAlbum>? albums,
    SirenAlbum? album,
    BasicDirectory? directory,
    SirenSong? song,
    bool? playing,
    bool? buffering,
    double? positionMs,
    double? durationMs,
    String? playbackError,
    List<BasicLyricLine>? lyrics,
    int? lyricIndex,
    bool? dark,
    List<SirenSong>? queue,
    int? queueIndex,
    String? queueMode,
    String? searchKind,
    String? searchGroup,
    String? searchGroupKey,
    bool? searchRemote,
    List<Map<String, Object?>>? searchRows,
    int? searchTotal,
    String? searchStatus,
    Map<String, List<int>>? searchGroups,
    String? lyricStatus,
    String? lyricsPreviewId,
    double? lyricsOffsetMs,
    double? lyricsGlobalOffsetMs,
    String? lyricMessage,
    String? playerStatus,
    bool? catalogLoaded,
    BasicSelection? selection,
    SirenSong? playingTrack,
    double? listPosition,
    String? songWiki,
    bool? songWikiLoading,
    int? selectedLane,
    bool? localCollectionsAvailable,
    int? localUnresolvedLikedIds,
    List<BasicLocalPlaylist>? localPlaylists,
    List<BasicLocalPlaylist>? serverPlaylists,
    List<String>? laneColumns,
    List<List<BasicListItem>>? laneItems,
    List<int>? laneOffsets,
    bool dropAlbum = false,
    bool dropDirectory = false,
    bool dropSong = false,
    bool dropSelection = false,
    bool dropPlayingTrack = false,
  }) {
    return BasicViewState(
      phase: phase ?? this.phase,
      loading: loading ?? this.loading,
      error: error ?? this.error,
      status: status ?? this.status,
      query: query ?? this.query,
      songs: songs ?? this.songs,
      albums: albums ?? this.albums,
      album: dropAlbum ? null : (album ?? this.album),
      directory: dropDirectory ? null : (directory ?? this.directory),
      song: dropSong ? null : (song ?? this.song),
      playing: playing ?? this.playing,
      buffering: buffering ?? this.buffering,
      positionMs: positionMs ?? this.positionMs,
      durationMs: durationMs ?? this.durationMs,
      playbackError: playbackError ?? this.playbackError,
      lyrics: lyrics ?? this.lyrics,
      lyricIndex: lyricIndex ?? this.lyricIndex,
      lyricsPreviewId: lyricsPreviewId ?? this.lyricsPreviewId,
      dark: dark ?? this.dark,
      queue: queue ?? this.queue,
      queueIndex: queueIndex ?? this.queueIndex,
      queueMode: queueMode ?? this.queueMode,
      searchKind: searchKind ?? this.searchKind,
      searchGroup: searchGroup ?? this.searchGroup,
      searchGroupKey: searchGroupKey ?? this.searchGroupKey,
      searchRemote: searchRemote ?? this.searchRemote,
      searchRows: searchRows ?? this.searchRows,
      searchTotal: searchTotal ?? this.searchTotal,
      searchStatus: searchStatus ?? this.searchStatus,
      searchGroups: searchGroups ?? this.searchGroups,
      lyricStatus: lyricStatus ?? this.lyricStatus,
      lyricsOffsetMs: lyricsOffsetMs ?? this.lyricsOffsetMs,
      lyricsGlobalOffsetMs: lyricsGlobalOffsetMs ?? this.lyricsGlobalOffsetMs,
      lyricMessage: lyricMessage ?? this.lyricMessage,
      playerStatus: playerStatus ?? this.playerStatus,
      catalogLoaded: catalogLoaded ?? this.catalogLoaded,
      selection: dropSelection ? null : (selection ?? this.selection),
      playingTrack: dropPlayingTrack
          ? null
          : (playingTrack ?? this.playingTrack),
      listPosition: listPosition ?? this.listPosition,
      songWiki: songWiki ?? this.songWiki,
      songWikiLoading: songWikiLoading ?? this.songWikiLoading,
      selectedLane: selectedLane ?? this.selectedLane,
      localCollectionsAvailable:
          localCollectionsAvailable ?? this.localCollectionsAvailable,
      localUnresolvedLikedIds:
          localUnresolvedLikedIds ?? this.localUnresolvedLikedIds,
      localPlaylists: localPlaylists ?? this.localPlaylists,
      serverPlaylists: serverPlaylists ?? this.serverPlaylists,
      laneColumns: laneColumns ?? this.laneColumns,
      laneItems: laneItems ?? this.laneItems,
      laneOffsets: laneOffsets ?? this.laneOffsets,
    );
  }
}

/// 一条可点条目：资料库一列里的一个条目（曲目或专辑），专辑页只承载该专辑曲目。
/// kind/index 指回 [BasicViewState] 的列表，绘制、命中、选中三处共用同一份顺序。
///
/// [id] 是条目身份（曲目 id / 专辑 id）。它是**唯一可靠的身份**：搜索结果列的
/// index 指回本次过滤后的列表，与 state.songs 的下标不同，只有 id 能对上选中。
class BasicListItem {
  const BasicListItem({
    required this.title,
    required this.kind,
    required this.index,
    this.id = '',
    this.cover = '',
    this.artist = '',
    this.album = '',
    this.albumId = '',
  });

  final String title;
  final String kind;
  final int index;

  /// 源条目 id（空串 = 旧调用点没给，退化为按 index 读源列表）。
  final String id;

  /// 源条目**自带**的真实封面 URL（空串 = 源条目没有图，不是"去别处猜一张"）。
  ///
  /// 原生 5×8 格的身份是 `siren:<kind>:<id>`（Engine::projectEmbeddedCells 的
  /// cellMap），封面只能按**这一格自己的**源条目取；用 filtered index 去
  /// state.songs 里翻封面会在搜索列/歌单列把别的歌的图贴上来。
  final String cover;

  /// 艺人名（真实字段，空串 = 上游没给）。
  final String artist;

  /// 专辑名（真实字段，空串 = 上游没给）。
  final String album;

  /// 歌曲条目的所属专辑 id：本条目没有自带封面时，允许用**同一张专辑**的封面
  /// （`qtSceneCoverOf` 的同一条规则），不允许跨条目借图。
  final String albumId;

  /// 稳定的源身份键：与 Qt 的 EmbeddedCellResources / Engine cellMap 同词。
  String get key => 'siren:$kind:$id';

  BasicListItem copyWith({
    String? title,
    String? kind,
    int? index,
    String? id,
    String? cover,
    String? artist,
    String? album,
    String? albumId,
  }) {
    return BasicListItem(
      title: title ?? this.title,
      kind: kind ?? this.kind,
      index: index ?? this.index,
      id: id ?? this.id,
      cover: cover ?? this.cover,
      artist: artist ?? this.artist,
      album: album ?? this.album,
      albumId: albumId ?? this.albumId,
    );
  }
}

/// 绘制与命中共用的一份列表真值。
///
/// 根页**只列 selectedLane 这一列**（Qt/src/MusicLibrary.cpp:195-207 sourceItems(lane)：
/// lane 越界为空，groupLane != lane 取 lists[lane]）。133 把专辑行与曲目行压进同一列
/// 是错的：Qt 的列是资料库列（搜索结果/喜欢的歌曲/我的歌单/全部歌曲/全部专辑），
/// 单平台也有五列，左右箭头换的是列。
///
/// [BasicViewState.songs] / [BasicViewState.albums] 由 controller 按当前列投好影
/// （搜索结果列是过滤后的集合，喜欢的歌曲列是本机 likedIDs 经曲库解析出的曲目，
/// 我的歌单列不含曲目，其余列是整库），这里不再二次过滤。
List<BasicListItem> basicLibraryItems(BasicViewState state) {
  if (state.directory != null) {
    // Qt/src/MusicLibrary.cpp:212-214 `directory ? directory->orderedSongs() : …`：
    // 目录打开时列表只有目录曲目（不再有专辑行），行号就是目录位置。
    return <BasicListItem>[
      for (var index = 0; index < state.songs.length; index++)
        BasicListItem(
          title: state.songs[index].title.isEmpty
              ? sirenUnknownTitle
              : state.songs[index].title,
          kind: 'song',
          index: index,
          id: state.songs[index].id,
          cover: state.songs[index].cover,
          artist: state.songs[index].artist,
          album: state.songs[index].album,
          albumId: state.songs[index].albumId,
        ),
    ];
  }
  final SirenAlbum? album = state.album;
  if (state.phase == BasicPhase.detail && album != null) {
    return <BasicListItem>[
      for (var index = 0; index < album.songs.length; index++)
        BasicListItem(
          title: album.songs[index].title.isEmpty
              ? sirenUnknownTitle
              : album.songs[index].title,
          kind: 'song',
          index: index,
          id: album.songs[index].id,
          cover: album.songs[index].cover,
          artist: album.songs[index].artist,
          album: album.songs[index].album,
          albumId: album.songs[index].albumId,
        ),
    ];
  }
  if (state.selectedLane == 4) {
    // 「全部专辑」列（Qt lane 4 的 lists[4]）。
    return <BasicListItem>[
      for (var index = 0; index < state.albums.length; index++)
        BasicListItem(
          title: state.albums[index].name.isEmpty
              ? '未命名专辑'
              : state.albums[index].name,
          kind: 'album',
          index: index,
          id: state.albums[index].id,
          cover: state.albums[index].cover,
          artist: state.albums[index].artist,
          album: state.albums[index].name,
        ),
    ];
  }
  if (state.selectedLane == basicSearchLane) {
    // 「搜索结果」列（Qt lane 0 的 lists[0]）。Qt 用 searchKind 一次只搜一类；
    // 基础版只有一个检索框，命中结果按 专辑行 + 曲目行 同列列出。
    // 空关键词 = 该列清空（Qt MusicLibrary.cpp:409-486 的 search() 清 lists[0] 后
    // 只上屏 '请输入 1–100 字关键词'），不是"列出全部"。
    if (state.query.trim().isEmpty) {
      return const <BasicListItem>[];
    }
    return <BasicListItem>[
      for (var index = 0; index < state.albums.length; index++)
        BasicListItem(
          title: state.albums[index].name.isEmpty
              ? '未命名专辑'
              : state.albums[index].name,
          kind: 'album',
          index: index,
          id: state.albums[index].id,
          cover: state.albums[index].cover,
          artist: state.albums[index].artist,
          album: state.albums[index].name,
        ),
      for (var index = 0; index < state.songs.length; index++)
        BasicListItem(
          title: state.songs[index].title.isEmpty
              ? sirenUnknownTitle
              : state.songs[index].title,
          kind: 'song',
          index: index,
          id: state.songs[index].id,
          cover: state.songs[index].cover,
          artist: state.songs[index].artist,
          album: state.songs[index].album,
          albumId: state.songs[index].albumId,
        ),
    ];
  }
  if (state.selectedLane == 3) {
    // 「全部歌曲」列（Qt lane 3 的 lists[3]）。
    return <BasicListItem>[
      for (var index = 0; index < state.songs.length; index++)
        BasicListItem(
          title: state.songs[index].title.isEmpty
              ? sirenUnknownTitle
              : state.songs[index].title,
          kind: 'song',
          index: index,
          id: state.songs[index].id,
          cover: state.songs[index].cover,
          artist: state.songs[index].artist,
          album: state.songs[index].album,
          albumId: state.songs[index].albumId,
        ),
    ];
  }
  if (state.selectedLane == 1) {
    // 「喜欢的歌曲」列（Qt lane 1 的 lists[1]）：本机 likedIDs 经 Flutter 曲库解析出的
    // 曲目（Qt/src/MusicSiren.cpp:296-335 只按 id 取 songs，不产生账号请求）。
    // 没有本机集合端口时一条也不编：Qt 的 lists[1] 来自 LocalCollections.likedIDs()，
    // 端口不存在就等于「还没查询过」，把整库曲目当成「喜欢的歌曲」是假数据。
    // 插件平台的服务端喜欢（`likedIDs`）同样进 `state.songs`，端口守卫对它不适用。
    if (!state.searchRemote && !state.localCollectionsAvailable) {
      return const <BasicListItem>[];
    }
    return <BasicListItem>[
      for (var index = 0; index < state.songs.length; index++)
        BasicListItem(
          title: state.songs[index].title.isEmpty
              ? sirenUnknownTitle
              : state.songs[index].title,
          kind: 'song',
          index: index,
          id: state.songs[index].id,
          cover: state.songs[index].cover,
          artist: state.songs[index].artist,
          album: state.songs[index].album,
          albumId: state.songs[index].albumId,
        ),
    ];
  }
  if (state.selectedLane == 2) {
    // 「我的歌单」列（Qt lane 2 的 lists[2]）。两个来源择一：
    // - 插件平台：服务端 `userPlaylists(uid)` 归到 [BasicViewState.serverPlaylists]；
    // - 塞壬/本地：collections->playlists()，端口不可用时一条也不编（诚实空态）。
    final List<BasicLocalPlaylist> playlists = state.searchRemote
        ? state.serverPlaylists
        : state.localPlaylists;
    if (!state.searchRemote && !state.localCollectionsAvailable) {
      return const <BasicListItem>[];
    }
    return <BasicListItem>[
      for (var index = 0; index < playlists.length; index++)
        BasicListItem(
          title: playlists[index].title.isEmpty
              ? '未命名歌单'
              : playlists[index].title,
          kind: 'playlist',
          index: index,
          id: playlists[index].id,
        ),
    ];
  }
  return const <BasicListItem>[];
}

/// 当前高亮条目（Qt MusicLibrary::libraryIndex()，Qt/src/MusicLibrary.cpp:196-212）。
///
/// 目录内用 directory.index —— Qt MusicDirectory::index 是位置真值，selectDirectory
/// 先写它再 choose（Qt/src/MusicDirectory.cpp:302-319）。
///
/// 资料库/专辑页按**身份**在 items 里找自己的行：先按 [BasicViewState.selection]
/// （一个 (kind, id) 的单值，等于 Qt 的 music.current）匹配；没有 selection 时再用当前
/// 曲目 id 匹配 kind == 'song' 行、用当前专辑 id 匹配 kind == 'album' 行。items 同时含
/// 专辑与曲目时行序与 state.songs 的下标并不相同（专辑行占前段），所以不能拿 state.songs
/// 的下标当行号，也没有固定偏移可加；标题可能重复，不能按标题匹配。
int basicSelectedItemIndex(BasicViewState state, List<BasicListItem> items) {
  if (items.isEmpty) {
    return 0;
  }
  final BasicDirectory? directory = state.directory;
  if (directory != null) {
    final int index = directory.index;
    return index < 0 || index >= items.length ? 0 : index;
  }
  final BasicSelection? selection = state.selection;
  if (selection != null) {
    for (var position = 0; position < items.length; position++) {
      final BasicListItem item = items[position];
      if (item.kind == selection.kind &&
          _itemIdAt(state, item) == selection.id) {
        return position;
      }
    }
  }
  final String songId = state.song?.id ?? '';
  if (songId.isNotEmpty) {
    for (var position = 0; position < items.length; position++) {
      final BasicListItem item = items[position];
      if (item.kind != 'song' ||
          item.index < 0 ||
          item.index >= state.songs.length) {
        continue;
      }
      if (state.songs[item.index].id == songId) {
        return position;
      }
    }
  }
  final String albumId = state.album?.id ?? '';
  if (albumId.isNotEmpty) {
    for (var position = 0; position < items.length; position++) {
      final BasicListItem item = items[position];
      if (item.kind != 'album' ||
          item.index < 0 ||
          item.index >= state.albums.length) {
        continue;
      }
      if (state.albums[item.index].id == albumId) {
        return position;
      }
    }
  }
  return 0;
}

/// 列表条目指回的源条目 id（越界/无源返回空串）。
///
/// 条目自带 id 时以它为身份真值（搜索结果列的 index 指回过滤后的列表，
/// 与 state.songs 下标并不相同）；只有旧调用点没给 id 时才按 index 回读源列表。
String _itemIdAt(BasicViewState state, BasicListItem item) {
  if (item.id.isNotEmpty) {
    return item.id;
  }
  if (item.index < 0) {
    return '';
  }
  if (item.kind == 'song') {
    if (item.index >= state.songs.length) {
      return '';
    }
    return state.songs[item.index].id;
  }
  if (item.kind == 'album') {
    if (item.index >= state.albums.length) {
      return '';
    }
    return state.albums[item.index].id;
  }
  return '';
}

/// 条目的选中身份（越界/无源返回 null）。
BasicSelection? basicItemSelection(BasicViewState state, BasicListItem item) {
  final String id = _itemIdAt(state, item);
  if (id.isEmpty) {
    return null;
  }
  return BasicSelection(kind: item.kind, id: id);
}

/// Qt MusicLibrary::searchSirenLocal 的歌曲匹配（MusicSiren.cpp:105-124）：
/// 空词全匹配，否则 title / album / artist 任一包含即命中（大小写不敏感）。
bool sirenSongMatches(SirenSong song, String query) {
  final String text = query.trim().toLowerCase();
  if (text.isEmpty) {
    return true;
  }
  return song.title.toLowerCase().contains(text) ||
      song.album.toLowerCase().contains(text) ||
      song.artist.toLowerCase().contains(text);
}

/// 专辑匹配（MusicSiren.cpp:118-124）：title / artist 任一包含。
bool sirenAlbumMatches(SirenAlbum album, String query) {
  final String text = query.trim().toLowerCase();
  if (text.isEmpty) {
    return true;
  }
  return album.name.toLowerCase().contains(text) ||
      album.artist.toLowerCase().contains(text);
}

List<SirenSong> filterSirenSongs(List<SirenSong> songs, String query) {
  final String text = query.trim();
  if (text.isEmpty) {
    return songs;
  }
  return <SirenSong>[
    for (final SirenSong song in songs)
      if (sirenSongMatches(song, text)) song,
  ];
}

List<SirenAlbum> filterSirenAlbums(List<SirenAlbum> albums, String query) {
  final String text = query.trim();
  if (text.isEmpty) {
    return albums;
  }
  return <SirenAlbum>[
    for (final SirenAlbum album in albums)
      if (sirenAlbumMatches(album, text)) album,
  ];
}

final RegExp _lrcRow = RegExp(r'^\s*((?:\[[-+]?\d+:\d+(?:[.:]\d+)?\])+)(.*)$');
final RegExp _lrcStamp = RegExp(r'\[([-+]?\d+):(\d+)(?:[.:](\d+))?\]');
final RegExp _lrcTranslation = RegExp(r'【(.*)】\s*$');
final RegExp _lrcOffsetTag = RegExp(
  r'^\s*\[offset:\s*([-+]?\d+)\s*\]\s*$',
  caseSensitive: false,
);
final RegExp _lrcMetaTag = RegExp(r'^\s*\[[a-zA-Z]+:[^\]]*\]\s*$');

/// 把插件返回的 lyrics-format 文档（Map）转成本地模型。
///
/// 形状见 `MusicBridge/lyrics-format.cjs` 的 `normalizeLyrics`：
/// `{version, source, timing: line|word|none, offsetMs, lines[{startMs,text,translation}], plainText}`。
/// 插件已经把 tlyric 合并进 `translation`，这里只做字段搬运，不重新解析 LRC。
BasicLyricsDocument basicLyricsFromDocument(Object? document) {
  if (document is! Map) {
    return BasicLyricsDocument.empty;
  }
  final List<BasicLyricLine> lines = <BasicLyricLine>[];
  final Object? rawLines = document['lines'];
  if (rawLines is List) {
    for (final Object? row in rawLines) {
      if (row is! Map) {
        continue;
      }
      final Object? start = row['startMs'];
      final String text = row['text'] is String ? row['text']! as String : '';
      final String translation = row['translation'] is String
          ? row['translation']! as String
          : '';
      if (text.isEmpty) {
        continue;
      }
      lines.add(
        BasicLyricLine(
          startMs: start is num ? start.toDouble() : 0,
          text: text,
          translation: translation,
        ),
      );
    }
  }
  lines.sort(
    (BasicLyricLine a, BasicLyricLine b) => a.startMs.compareTo(b.startMs),
  );
  final Object? offset = document['offsetMs'];
  final String plainText = document['plainText'] is String
      ? document['plainText']! as String
      : '';
  return BasicLyricsDocument(
    lines: lines,
    offsetMs: offset is num ? offset.toDouble() : 0,
    plainText: plainText,
    timed: lines.isNotEmpty,
  );
}

/// 解析 LRC 文本（对齐 MusicBridge/lyrics-format.cjs parseLrc :35-53 与
/// normalizeLyrics :128-213）：多时间戳展开、【…】翻译、[offset:…] 偏移、按 startMs 排序。
BasicLyricsDocument parseBasicLyrics(String raw) {
  final String text = _cleanLyricText(raw);
  final List<BasicLyricLine> lines = <BasicLyricLine>[];
  final List<String> plain = <String>[];
  double offsetMs = 0;
  for (final String row in text.split('\n')) {
    final RegExpMatch? tag = _lrcOffsetTag.firstMatch(row);
    if (tag != null) {
      offsetMs = _parseOffset(tag.group(1));
      continue;
    }
    final RegExpMatch? match = _lrcRow.firstMatch(row);
    if (match == null) {
      final String trimmed = row.trim();
      if (trimmed.isEmpty || _lrcMetaTag.hasMatch(trimmed)) {
        continue;
      }
      plain.add(trimmed);
      continue;
    }
    final String stamps = match.group(1) ?? '';
    final String body = (match.group(2) ?? '').trim();
    final RegExpMatch? translationMatch = _lrcTranslation.firstMatch(body);
    final String translation = translationMatch == null
        ? ''
        : (translationMatch.group(1) ?? '').trim();
    final String content = translationMatch == null
        ? body
        : body.substring(0, translationMatch.start).trim();
    for (final RegExpMatch stamp in _lrcStamp.allMatches(stamps)) {
      final int minutes = int.tryParse(stamp.group(1) ?? '') ?? 0;
      final int seconds = int.tryParse(stamp.group(2) ?? '') ?? 0;
      final String fractionText = stamp.group(3) ?? '';
      final double fraction = fractionText.isEmpty
          ? 0
          : (double.tryParse('0.$fractionText') ?? 0);
      final double startMs =
          ((minutes * 60) + seconds) * 1000 + (fraction * 1000);
      lines.add(
        BasicLyricLine(
          startMs: startMs.roundToDouble(),
          text: content,
          translation: translation,
        ),
      );
    }
  }
  lines.sort(
    (BasicLyricLine left, BasicLyricLine right) =>
        left.startMs.compareTo(right.startMs),
  );
  return BasicLyricsDocument(
    lines: List<BasicLyricLine>.unmodifiable(lines),
    offsetMs: offsetMs,
    plainText: lines.isEmpty ? plain.join('\n') : '',
    timed: lines.isNotEmpty,
  );
}

double _parseOffset(String? raw) {
  final int value = int.tryParse((raw ?? '').trim()) ?? 0;
  const double limit = 10000;
  if (value.toDouble() > limit) {
    return limit;
  }
  if (value.toDouble() < -limit) {
    return -limit;
  }
  return value.toDouble();
}

String _cleanLyricText(String raw) {
  String text = raw.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
  if (text.length > sirenMaxLyricLength) {
    text = text.substring(0, sirenMaxLyricLength);
  }
  return text
      .replaceAll('&nbsp;', ' ')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'")
      .replaceAll('&amp;', '&');
}
