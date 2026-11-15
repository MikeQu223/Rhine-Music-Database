/// Qt → Flutter 迁移 · BASIC-89（塞壬唱片基本版）的冻结数据契约。
///
/// owner：lane A。本文件是跨 lane 契约 v1 的唯一写者，改名必须先报 BASIC-89 协调者。
/// 真值来源（只读）：
/// - /home/aibeto/code/Rhine-Music-Database/MusicBridge/client/siren.mjs
///   songItem :189-216、albumItem :218-255、detail :414-439、playback :482-495、lyrics :497-513
/// - /home/aibeto/code/Rhine-Music-Database/Qt/src/MusicSiren.cpp
///   曲库读取 :46-88、本地搜索匹配字段 :105-124、文案 :50/:63/:78-79/:181-183
/// - /home/aibeto/code/Rhine-Music-Database/MusicBridge/lyrics-format.cjs
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
  int get hashCode => Object.hash(id, title, artist, album, albumId, cover, sourceUrl, lyricUrl, durationMs);

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
    this.virtual = true,
    this.parent,
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

  /// 上一级目录（null = 资料库根）。
  final BasicDirectory? parent;

  /// 复制并改选中行/游标/曲目（Qt 直接改 MusicDirectory 的可变字段）。
  BasicDirectory copyWith({
    List<SirenSong>? songs,
    List<String>? ids,
    int? cursor,
    int? trackCount,
    int? index,
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
      virtual: virtual,
      parent: parent,
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
  const BasicLyricLine({required this.startMs, required this.text, this.translation = ''});

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

/// 界面只读的状态快照；唯一写者是 BasicController。
///
/// 冻结契约要求的 getter（phase/loading/error/status/query/songs/albums/album/song/playing/
/// buffering/positionMs/durationMs/playbackError/lyrics/lyricIndex/dark）在这里都是 final 字段，
/// 读取方式与 getter 完全一致；其余字段是 lane A 追加的空态/播放辅助信息。
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
    this.dark = true,
    this.queue = const <SirenSong>[],
    this.queueIndex = -1,
    this.lyricStatus = 'idle',
    this.lyricMessage = '',
    this.playerStatus = '',
    this.catalogLoaded = false,
    this.selection,
    this.playingTrack,
    this.listPosition,
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

  /// 当前曲目（正在播放或刚选中；歌词页与播放条都以它为准）。
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

  /// 活动行下标（-1 = 未到第一行或没有时间轴）。
  final int lyricIndex;

  /// 深色模式（基础版固定跟随构造参数，不做主题切换）。
  final bool dark;

  /// 播放队列（与 MusicPlayer.queue 同步的只读投影）。
  final List<SirenSong> queue;

  /// 队列中当前行（-1 = 空队列）。
  final int queueIndex;

  /// 歌词状态：'idle' / 'ready' / 'plain' / 'empty'（对齐 LyricsController.status 词表）。
  final String lyricStatus;

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
    String? lyricStatus,
    String? lyricMessage,
    String? playerStatus,
    bool? catalogLoaded,
    BasicSelection? selection,
    SirenSong? playingTrack,
    double? listPosition,
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
      dark: dark ?? this.dark,
      queue: queue ?? this.queue,
      queueIndex: queueIndex ?? this.queueIndex,
      lyricStatus: lyricStatus ?? this.lyricStatus,
      lyricMessage: lyricMessage ?? this.lyricMessage,
      playerStatus: playerStatus ?? this.playerStatus,
      catalogLoaded: catalogLoaded ?? this.catalogLoaded,
      selection: dropSelection ? null : (selection ?? this.selection),
      playingTrack: dropPlayingTrack ? null : (playingTrack ?? this.playingTrack),
      listPosition: listPosition ?? this.listPosition,
    );
  }
}

/// 一条可点条目：资料库首屏同时承载专辑与曲目，专辑页只承载该专辑曲目。
/// kind/index 指回 [BasicViewState] 的列表，绘制、命中、选中三处共用同一份顺序。
class BasicListItem {
  const BasicListItem({required this.title, required this.kind, required this.index});

  final String title;
  final String kind;
  final int index;
}

/// 绘制与命中共用的一份列表真值。
List<BasicListItem> basicLibraryItems(BasicViewState state) {
  if (state.directory != null) {
    // Qt/src/MusicLibrary.cpp:212-214 `directory ? directory->orderedSongs() : …`：
    // 目录打开时列表只有目录曲目（不再有专辑行），行号就是目录位置。
    return <BasicListItem>[
      for (var index = 0; index < state.songs.length; index++)
        BasicListItem(
          title: state.songs[index].title.isEmpty ? sirenUnknownTitle : state.songs[index].title,
          kind: 'song',
          index: index,
        ),
    ];
  }
  final SirenAlbum? album = state.album;
  if (state.phase == BasicPhase.detail && album != null) {
    return <BasicListItem>[
      for (var index = 0; index < album.songs.length; index++)
        BasicListItem(
          title: album.songs[index].title.isEmpty ? sirenUnknownTitle : album.songs[index].title,
          kind: 'song',
          index: index,
        ),
    ];
  }
  return <BasicListItem>[
    for (var index = 0; index < state.albums.length; index++)
      BasicListItem(
        title: state.albums[index].name.isEmpty ? '未命名专辑' : state.albums[index].name,
        kind: 'album',
        index: index,
      ),
    for (var index = 0; index < state.songs.length; index++)
      BasicListItem(
        title: state.songs[index].title.isEmpty ? sirenUnknownTitle : state.songs[index].title,
        kind: 'song',
        index: index,
      ),
  ];
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
      if (item.kind == selection.kind && _itemIdAt(state, item) == selection.id) {
        return position;
      }
    }
  }
  final String songId = state.song?.id ?? '';
  if (songId.isNotEmpty) {
    for (var position = 0; position < items.length; position++) {
      final BasicListItem item = items[position];
      if (item.kind != 'song' || item.index < 0 || item.index >= state.songs.length) {
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
      if (item.kind != 'album' || item.index < 0 || item.index >= state.albums.length) {
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
String _itemIdAt(BasicViewState state, BasicListItem item) {
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
  return album.name.toLowerCase().contains(text) || album.artist.toLowerCase().contains(text);
}

List<SirenSong> filterSirenSongs(List<SirenSong> songs, String query) {
  final String text = query.trim();
  if (text.isEmpty) {
    return songs;
  }
  return <SirenSong>[for (final SirenSong song in songs) if (sirenSongMatches(song, text)) song];
}

List<SirenAlbum> filterSirenAlbums(List<SirenAlbum> albums, String query) {
  final String text = query.trim();
  if (text.isEmpty) {
    return albums;
  }
  return <SirenAlbum>[for (final SirenAlbum album in albums) if (sirenAlbumMatches(album, text)) album];
}

final RegExp _lrcRow = RegExp(r'^\s*((?:\[[-+]?\d+:\d+(?:[.:]\d+)?\])+)(.*)$');
final RegExp _lrcStamp = RegExp(r'\[([-+]?\d+):(\d+)(?:[.:](\d+))?\]');
final RegExp _lrcTranslation = RegExp(r'【(.*)】\s*$');
final RegExp _lrcOffsetTag = RegExp(r'^\s*\[offset:\s*([-+]?\d+)\s*\]\s*$', caseSensitive: false);
final RegExp _lrcMetaTag = RegExp(r'^\s*\[[a-zA-Z]+:[^\]]*\]\s*$');

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
    final String translation = translationMatch == null ? '' : (translationMatch.group(1) ?? '').trim();
    final String content = translationMatch == null
        ? body
        : body.substring(0, translationMatch.start).trim();
    for (final RegExpMatch stamp in _lrcStamp.allMatches(stamps)) {
      final int minutes = int.tryParse(stamp.group(1) ?? '') ?? 0;
      final int seconds = int.tryParse(stamp.group(2) ?? '') ?? 0;
      final String fractionText = stamp.group(3) ?? '';
      final double fraction = fractionText.isEmpty ? 0 : (double.tryParse('0.' + fractionText) ?? 0);
      final double startMs = ((minutes * 60) + seconds) * 1000 + (fraction * 1000);
      lines.add(BasicLyricLine(startMs: startMs.roundToDouble(), text: content, translation: translation));
    }
  }
  lines.sort((BasicLyricLine left, BasicLyricLine right) => left.startMs.compareTo(right.startMs));
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
