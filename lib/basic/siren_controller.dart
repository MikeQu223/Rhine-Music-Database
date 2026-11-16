/// BASIC-89 lane A：Siren 基本版的唯一业务 authority（导航 / 播放队列 / 歌词跟随）。
///
/// 分工（冻结契约 v1）：
///  - 本文件是**唯一**持有播放队列与当前曲的地方；UI 只读 [state]、只调这里的方法。
///  - 播放进度**只**来自 lane B 的 BasicAudioPort（android.media.MediaPlayer 的真实读数）：
///    经由 MusicPlayer.state 的 position/duration 进入 [state]；本文件从不 position += dt。
///  - 播放传输状态机复用 lib/domain/player/music_player.dart（MusicPlayer::tick 的移植），
///    这里只提供三个端口实现：MediaHostPort / PreferencePort / PlaybackEnginePort。
///  - 歌词复用 lib/domain/lyrics/lyrics_controller.dart 的 index 语义（upper_bound + offset），
///    位置同样只吃 native 读数。
///  - seekToFraction 只有两步：把比例命令下发 native（MusicPlayer.seek → mediaControl('seek')），
///    再用「native 已报的真实时长 × 比例」调一次 lyrics.sync 立即重算活动行；
///    绝不在本地先把 position 改成目标值，进度只认 native 回报（BASIC-89 协调者 seq5 裁决 3b）。
///  - ticker 只在 boot() 启动一次（Timer.periodic 100ms），dispose() 必 cancel；
///    _pump 在 _lyrics 尚未创建时（LyricsController.create 是异步的）只跑 MusicPlayer.tick，
///    不碰歌词控制器，因此不会空引用（裁决 3a）。
///
/// 真值来源（只读）：
///  - Qt/src/MusicSiren.cpp:36-88（曲库读取 / 失败文案 / generation）、:100-124（本地搜索匹配）、
///    :181-183（'找到 N 条结果' / '没有匹配的音乐'）、:195（'塞壬唱片曲库尚未加载'）、
///    :242（'已打开：…'）。
///  - Qt/src/MusicLibrary.cpp:339（'读取失败：'）。
///  - Qt/src/MusicPlayer.cpp:289（'正在准备：'）、:429（'正在播放：'）、:591-613（playbackStarted）、
///    :617-628（fail）。
///  - Qt/src/AudioPlayer.cpp:430-443（mediaState 键集，position/duration 为毫秒）。
///  - MusicBridge/client/siren.mjs:482-495（播放前 fresh 读直链 / '塞壬唱片未提供可播放音源'）、
///    :497-513（歌词文本与 1e6 上限）。
///  - Qt/src/LyricsController.cpp:281（'暂无歌词'）。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../domain/lyrics/lyrics_controller.dart';
import '../domain/player/music_player.dart';
import 'basic_art_cache.dart';
import 'basic_media_session.dart';
import 'basic_models.dart';
import '../platform/media_session.dart';
import 'platform_playback.dart';
import 'siren_repository.dart';

/// 曲库读取中的状态文案（Qt/src/MusicSiren.cpp:50）。
const String sirenCatalogLoadingStatus = '正在读取塞壬唱片曲库…';

/// 曲库读取失败的前缀（Qt/src/MusicSiren.cpp:63）。
const String sirenCatalogFailurePrefix = '塞壬唱片曲库读取失败：';

/// 曲库已加载的状态文案前缀（Qt/src/MusicSiren.cpp:78-79）。
const String sirenCatalogLoadedPrefix = '已加载塞壬唱片曲库：';

/// 曲库尚未加载的状态文案（Qt/src/MusicSiren.cpp:195）。
const String sirenLibraryUnloadedStatus = '塞壬唱片曲库尚未加载';

/// 详情读取失败的前缀（Qt/src/MusicLibrary.cpp:339）。
const String sirenDetailFailurePrefix = '读取失败：';

/// 详情读取中的状态文案（Qt/src/MusicLibrary.cpp:138 的 '正在读取…请稍候…' 模板，列名取'专辑'）。
const String sirenAlbumLoadingStatus = '正在读取专辑，请稍候…';

/// 上游没有可播放音源时的文案（MusicBridge/client/siren.mjs:485）。
const String sirenNoSourceMessage = '塞壬唱片未提供可播放音源';

/// 无歌词时的文案（Qt/src/LyricsController.cpp:281）。
const String sirenEmptyLyricsMessage = '暂无歌词';

/// 歌词时间轴最多接受的行数（lib/domain/lyrics/lyrics_timeline.dart 的
/// validLyricsDocument 上限 5000；超出部分不参与时间轴）。
const int sirenMaxLyricLines = 5000;

/// 「全部歌曲」虚拟目录的 id / key / 标题（Qt/src/MusicSiren.cpp:211-218）。
const String sirenAllSongsId = 'siren-all';
const String sirenAllSongsKey = 'siren:playlist:all';
const String sirenAllSongsTitle = '全部歌曲';

/// 「全部歌曲」目录的描述（Qt/src/MusicSiren.cpp:218）。
const String sirenAllSongsDescription = '塞壬唱片全部歌曲';

/// 打开目录/详情后的状态文案前缀（Qt/src/MusicSiren.cpp:242、MusicDirectory.cpp:445）。
const String sirenOpenedPrefix = '已打开：';

/// 返回上一级的状态文案前缀（Qt/src/MusicDirectory.cpp:447）。
const String sirenReturnedPrefix = '已返回：';

/// provider 的显示名（Qt/src/MusicApi.cpp:16-17 的 providerName()：siren → '塞壬唱片'）。
const String sirenProviderLabel = '塞壬唱片';

/// Siren 基本版的单一 authority。
///
/// 构造注入 lane B 的 [BasicAudioPort]；[repository] 可注入（测试/替换 baseUri），
/// [dark] 只影响 [state].dark（基础版不做主题切换）。
class BasicController extends ChangeNotifier implements BasicMediaSessionCommands {
  BasicController({
    required BasicAudioPort audio,
    SirenRepository? repository,
    bool dark = true,
    BasicLocalCollections? collections,
    MediaSessionPort? mediaSessionPort,
    BasicArtCache? artCache,
    PreferencePort? preferences,
  })  : _audio = audio,
        _preferencesPort = preferences,
        _repository = repository ?? SirenRepository(),
        _ownsRepository = repository == null,
        _dark = dark,
        _collections = collections {
    _state = BasicViewState(dark: dark);
    _player = MusicPlayer(
      media: _BasicMediaHost(this),
      // 真实面板偏好端口（SharedPreferences）。没有注入时退到内存端口：
      // 播放队列的偏好读写在测试/桌面预览里也不必落盘。
      preferences: _preferencesPort ?? _MemoryPreferences(),
      engine: _BasicPlaybackEngine(this),
      provider: _providerName,
    );
    _player.addListener(_onPlayerChanged);
    _audio.addListener(_onAudioStateChanged);
    // 系统媒体控件（通知/锁屏/蓝牙）不是第二套播放器：它只把真实动作交回
    // 本控制器，并把真实在播身份与真实 audio 读数报出去。没注入端口（widget
    // 测试、桌面预览）就没有这层，一切照旧。
    final MediaSessionPort? port = mediaSessionPort;
    if (port != null) {
      _mediaSession = BasicMediaSessionAdapter(port: port, commands: this);
      // 封面落盘：系统通知只认本地文件（MediaSessionHost 用 BitmapFactory.decodeFile），
      // 而 SirenSong.cover 是远端 URL，所以必须有一层"URL -> 私有目录里的真实文件"。
      // 目录来自同一个端口的 cacheDirectory()；没有端口（widget 测试、桌面预览）就没有
      // 缓存，也不写盘。
      _artCache = artCache ?? BasicArtCache(directory: port.cacheDirectory);
    } else {
      _artCache = artCache;
    }
  }

  /// 系统媒体控件适配器；未注入 [MediaSessionPort] 时为 null。
  BasicMediaSessionAdapter? _mediaSession;

  /// 通知封面的本地缓存；没有媒体端口也没有注入时为 null（不落盘、不触网）。
  BasicArtCache? _artCache;

  /// 当前已落盘封面所属的曲目与来源 URL（防重复请求、防止 A/B 串台）。
  String _artTrackId = '';
  String _artUrl = '';

  /// 已落盘的封面绝对路径；只有 [_artTrackId] 与当前播放身份一致时才上报。
  String _artPath = '';

  /// 同一 (id, url) 已经发过几次请求。
  ///
  /// 有界重试：瞬时失败（离线、目录暂时不可写、非 200）不该让这首曲子整个会话
  /// 都永远没有封面，但也不能变成一个高频重试循环 —— 所以只给 2 次机会，
  /// 用完就如实留空（LEAD 2026-11-16 的 M2 反例）。
  int _artAttempts = 0;

  /// 首次请求 + 1 次重试。
  static const int _artMaxAttempts = 2;

  /// 当前在飞请求的代次；-1 表示没有在飞请求。
  ///
  /// 没有这个闸门时，起步阶段每次 _publish（_player.play 的 _emit、_startPlayback、
  /// buffering 上报）都会新建一个闭包：HTTP 层有 inflight 去重，所以只有一个真请求，
  /// 但闭包不去重 → 一次失败会被多个闭包各记一次额度，重试机会当场被吃光。
  int _artInFlight = -1;

  static String _providerName() => sirenProvider;

  final BasicAudioPort _audio;
  final SirenRepository _repository;
  final bool _ownsRepository;
  /// 真实面板偏好端口（可注入）。[BasicApp] 生产路径注入 SharedPreferences 端口，
  /// 于是 `single-play-mode` 等键与设置页写的是**同一份**存储，不是两份真值。
  final PreferencePort? _preferencesPort;

  /// 明暗主题。Qt 侧主题由面板偏好驱动；这里只有这一个真值源，
  /// [setDark] 是设置页“界面配色”唯一的写入点（[state].dark 每帧从这里取）。
  bool _dark;

  /// 本机集合的只读端口（Qt `LocalCollections` 的收窄投影）；null = 基础版没接上。
  ///
  /// 它只被**查询**（likedIds / playlists），不写入、不持久化：收藏/歌单的写入口和编辑
  /// UI 都不在基础版范围内，也没有任何登录/账号条件（Qt/src/MusicSiren.cpp:6-21）。
  final BasicLocalCollections? _collections;

  /// 本机集合是否真的接入并查询过（Qt `collections != nullptr` 同义）。
  bool _localCollectionsAvailable = false;

  /// 「喜欢的歌曲」列的行：本机 likedIDs 按本机顺序经曲库解析出的曲目。
  ///
  /// 解析不到的 id 不造行（基础版没有逐首详情补全），空态文案会说明“暂不可用”或
  /// “暂无喜欢的歌曲”，见 [basicLaneEmptyNotice]。
  List<SirenSong> _likedSongs = const <SirenSong>[];

  /// 「我的歌单」列的行（本机 playlists() 的投影）。
  List<BasicLocalPlaylist> _localPlaylists = const <BasicLocalPlaylist>[];

  /// 源 likedIDs 里已存在、但曲库还解析不出的条数（Qt 会拿这些 id 再补 songs，
  /// Qt/src/MusicSiren.cpp:296-322）。它让“非空但暂时显示不出来”不等于“空收藏”。
  int _localUnresolvedLikedIds = 0;

  /// Qt `rowMemory[lane]`（0..7 的页内行）：`openSirenAllSongs` 用
  /// `anchor = destination*8 + rowMemory[destination]` 决定目录的折列锚点
  /// （Qt/src/MusicSiren.cpp:229-240）。基础版没有 physicalSlots，这里只是逻辑行号。
  final List<int> _rowMemory = List<int>.filled(basicSirenColumns.length, 0);

  /// Qt `offsets[lane]`（Qt/src/MusicLibrary.h:148-149）：根列滚动窗口的起始绝对行号。
  ///
  /// `next` 走到边缘时 Qt 会写成 `offsets[lane] = next - target`（可能为负，
  /// Qt/src/MusicLibrary.cpp:651-663），随后 `wrap(offsets[lane]+row, count)` 再取模。
  /// 它与 [_rowMemory] 一起决定 open-all 的目录 anchor，不能只留 rowMemory。
  final List<int> _laneOffsets = List<int>.filled(basicSirenColumns.length, 0);

  late final MusicPlayer _player;
  late BasicViewState _state;

  Future<LyricsController>? _lyricsFuture;
  LyricsController? _lyrics;
  BasicLyricsDocument _lyricDoc = BasicLyricsDocument.empty;

  Timer? _ticker;
  final Stopwatch _clock = Stopwatch();

  List<SirenSong> _catalogSongs = const <SirenSong>[];
  List<SirenAlbum> _catalogAlbums = const <SirenAlbum>[];
  Map<String, SirenSong> _songById = <String, SirenSong>{};

  BasicPhase _phase = BasicPhase.boot;
  bool _loading = false;
  String _error = '';
  String _status = sirenCatalogLoadingStatus;
  String _query = '';
  SirenAlbum? _album;

  /// 已打开的虚拟目录（null = 资料库根；Qt MusicLibrary::directory 的收窄投影）。
  BasicDirectory? _directory;
  SirenSong? _song;

  /// 列表选中身份（Qt `music.current`）；[_song] 是它的 song 投影。
  ///
  /// 与播放身份严格分开：播放换曲只改 [_player]，不写这里（播放曲目见 _publish 的
  /// playingTrack）。Qt 的 archive 选中也只动 MusicLibrary 的 current/selectedPhysical。
  BasicSelection? _selection;

  /// 曲目列滚动位置（单位：条目，小数 = 两项之间）。
  ///
  /// 这是**唯一的连续窗口真值**：列表拖动过程中（松手前）就写这里并投影给 Qt 的
  /// 3D 场景，Qt 的 3D 拖动/滚轮也回写到这同一个值。两侧都只是同一份状态的
  /// 投影，任何一侧都不持有第二份窗口位置（用户 P0 #1：双向连续同步）。
  double _listPosition = 0;

  /// Qt 3D 侧一次拖动/滚轮序列的起点窗口（条目）。用来把原生的连续增量折成
  /// 绝对位置，并折断 list→Qt→list 的回声：同一位置再回写时不再产生新状态。
  double? _nativeScrollOrigin;

  /// 曲库失败后的有界自动重试次数（冷启动 count=0 的真实 loading/error/retry）。
  int _catalogRetries = 0;
  Timer? _catalogRetryTimer;

  /// 冷启动曲库的自动重试上限：一次瞬时失败不该让首页永远停在空列表。
  static const int maxCatalogRetries = 3;

  /// [_laneItemTable] 的签名缓存（见该方法的失效规则）。
  String _laneItemsSignature = '';
  List<List<BasicListItem>>? _laneItemsCache;

  /// 当前资料库列（Qt `MusicLibrary::selectedLane`，Qt/src/MusicLibrary.cpp:167 起）：
  /// 根页列表只承载这一列，←/→ 按 [basicSirenSourceOrder] 循环换列。
  int _selectedLane = basicDefaultLane;

  /// 每列各自的滚动位置（单位条目），只在目录外/无父目录这类退化路径上用。
  ///
  /// 常规的换列恢复走 Qt showSource 的窗口语义 `wrap(offsets[lane]+rowMemory[lane], count)`，
  /// 见 [_showSourceLane]；这里保留的是「退出目录后没有父目录可复位」时的落点。
  final List<double> _lanePositions = List<double>.filled(basicSirenColumns.length, 0);
  BasicPhase? _phaseBeforeLyrics;
  bool _catalogLoaded = false;
  bool _booted = false;
  bool _disposed = false;

  /// 曲库 / 详情 / 选曲 / 播放四类异步的世代号；迟到响应整份丢弃
  /// （Qt 用 MusicApi::send 的 valid(generation) 做同一件事，Qt/src/MusicApi.cpp:98-100）。
  int _catalogGeneration = 0;
  int _detailGeneration = 0;
  int _songGeneration = 0;
  int _activeGeneration = 0;

  /// native 的 completed 上升沿计数（Qt AudioPlayer 的 ended 序号语义）。
  int _endedSerial = 0;
  bool _completedSeen = false;

  /// 界面唯一可读的状态快照。
  BasicViewState get state => _state;

  /// 启动：加载真实曲库并开始 0.1s 轮询（Qt 的 poll 等价物）。
  Future<void> boot() async {
    if (_booted || _disposed) {
      return;
    }
    _booted = true;
    _phase = BasicPhase.boot;
    _loading = true;
    _error = '';
    _status = sirenCatalogLoadingStatus;
    _refreshLocalCollections();
    _publish();
    _startTicker();
    // 预热歌词偏好（异步端口），失败不影响曲库。
    unawaited(_ensureLyrics());
    await _loadCatalog();
  }

  /// 失败重试：曲库没加载过就重读曲库；否则重开当前详情页（Qt 的 retry 语义）。
  Future<void> retry() async {
    if (_disposed) {
      return;
    }
    if (!_catalogLoaded) {
      _phase = BasicPhase.boot;
      await _loadCatalog();
      return;
    }
    if (_phase == BasicPhase.detail) {
      final SirenAlbum? album = _album;
      if (album != null) {
        await openAlbum(album);
        return;
      }
      final SirenSong? song = _song;
      if (song != null) {
        await openSong(song);
        return;
      }
    }
    await _loadCatalog();
  }

  /// 曲库页搜索（Qt/src/MusicSiren.cpp:100-124 的匹配字段、:181-183 的结果文案）。
  Future<void> setQuery(String value) async {
    if (_disposed) {
      return;
    }
    if (_directory != null) {
      // Qt/src/MusicSiren.cpp:184-188：每次搜索结束都 showSource(0) → leaveDirectory(false)
      // （Qt MusicLibrary.cpp:556-570 无条件离目录）。目录打开时先回资料库根，关键词再作用于
      // 完整曲库（目录本身不参与过滤）；即使关键词没变也不能留在目录里——否则下面的
      // '已加载…N 首 / M 张专辑' 文案会与仍在显示的目录列表自相矛盾。
      _leaveDirectory(restore: false);
    }
    _query = value;
    _error = '';
    // Qt/src/MusicSiren.cpp:181-183：检索结束 showSource(0) + modeRequested("archive")，
    // 列表切到「搜索结果」列（lane 0），并重置该列的滚动窗口。
    _selectedLane = basicSearchLane;
    _listPosition = 0;
    _lanePositions[basicSearchLane] = 0;
    if (!_catalogLoaded) {
      if (!_loading) {
        _status = sirenLibraryUnloadedStatus;
      }
      _publish();
      return;
    }
    final int count =
        value.trim().isEmpty ? 0 : _visibleSongs().length + _visibleAlbums().length;
    if (value.trim().isEmpty) {
      // Qt MusicLibrary.cpp:409-486：空关键词清 lists[0]，只留提示文案。
      // 状态栏那句是 MusicLibrary::search 的空/超长早退（:441-455
      // `status = "请输入 1–<maximum> 字关键词"`；塞壬不是 qq，maximum = 100）；
      // basicLaneEmptyNotice(0) 是列表区的空列提示，两者不是同一处文案。
      _status = '请输入 1\u2013100 字关键词';
    } else if (count == 0) {
      _status = '没有匹配的音乐';
    } else {
      _status = '找到 $count 条结果';
    }
    if (count > 0) {
      // Qt 的 showSource(0) 会 observe 该列的第一格（只选中，不播放）。
      final String status = _status;
      _selectRow(basicLibraryItems(_probeState()), 0);
      _status = status;
    }
    _publish();
  }

  /// 打开专辑详情：GET /api/album/<id>/detail（siren.mjs:298-307）。
  Future<void> openAlbum(SirenAlbum album) async {
    if (_disposed) {
      return;
    }
    final int generation = ++_detailGeneration;
    _album = album;
    _phase = BasicPhase.detail;
    // 详情页的列表是这张专辑的曲目，行号从头开始：选中身份交给后面的选曲路径重设。
    _selection = null;
    _listPosition = 0;
    _loading = true;
    _error = '';
    _status = sirenAlbumLoadingStatus;
    _publish();
    try {
      final SirenAlbum detailed = await _repository.albumDetail(album);
      if (generation != _detailGeneration) {
        // 迟到的专辑详情：整份丢弃，loading 保持（Qt 的 valid 失败分支根本不进 callback）。
        return;
      }
      _album = detailed;
      for (final SirenSong song in detailed.songs) {
        _songById[song.id] = song;
      }
      _loading = false;
      _status = '已打开：${detailed.name}';
    } on Object catch (error) {
      if (generation != _detailGeneration) {
        return;
      }
      _loading = false;
      _error = _messageOf(error);
      _status = sirenDetailFailurePrefix + _error;
    }
    _publish();
  }

  /// 选中并播放一首歌：队列由这里产生，播放前 fresh 读详情由 [_startPlayback] 统一做。
  ///
  /// 不在这里缓存 sourceUrl（带时效签名，siren.mjs:293-296）：每次播放都走一次
  /// /api/song/<id>，与 Qt MusicPlayer::prepare 的行为一致。
  ///
  /// [play] = false 时只进详情/只选中，不动播放器与队列（Qt NativeHudController.cpp:626-638
  /// 的 'open' 只在 preference('detail-autoplay') == 'on' 时才 play）。浏览不该出声。
  /// 设置页读的唯一主题真值。
  bool get dark => _dark;

  /// 界面配色：只改本控制器的主题真值并重绘（HUD/弹层/输入框/原生场景都读
  /// [state].dark），不重建 controller、不断播放。
  void setDark(bool value) {
    if (_disposed || _dark == value) {
      return;
    }
    _dark = value;
    _state = _state.copyWith(dark: value);
    _publish();
  }

  /// 进入详情页自动播放（Qt NativeHudController.cpp:626-638 的 detail-autoplay）。
  bool get detailAutoplay => _detailAutoplay;
  bool _detailAutoplay = false;
  void setDetailAutoplay(bool value) {
    if (_disposed || _detailAutoplay == value) {
      return;
    }
    _detailAutoplay = value;
    _publish();
  }

  /// 「打开」（Qt 动作 `open`）进入详情后的自动播放。
  ///
  /// 只由**显式打开**触发；单纯浏览/翻行（`music:index:<i>`、`music:slot:<i>`）永远不
  /// 经过这里，所以设置关着时浏览一声不出。开启时走 Qt 的 `music.play(false)` 同义路径：
  /// 不带 source 的单曲播放——**不替换**播放列表，与 single-play-mode 的
  /// append/replace 选择完全独立（Qt 注释「自动播放不触发"替换播放列表"」）。
  ///
  /// 已经在播这首就不重复起播（避免 `open` 打断当前播放位置）。
  Future<void> autoplayDetailIfEnabled(SirenSong song) async {
    if (_disposed || !_detailAutoplay) {
      return;
    }
    if (_playingTrackOf()?.id == song.id && _audio.state.playing) {
      return;
    }
    _status = '正在准备：${song.title}';
    _publish();
    _player.play(song.toTrack());
  }

  /// 点击播放单曲：true = 仅把当前单曲加到队尾并选中（append），
  /// false = 用“所在列表”替换队列（replace，Qt MusicLibrary 默认）。
  bool get singlePlayAppend => _singlePlayAppend;
  bool _singlePlayAppend = false;
  void setSinglePlayAppend(bool value) {
    if (_disposed || _singlePlayAppend == value) {
      return;
    }
    _singlePlayAppend = value;
    _publish();
  }

  Future<void> openSong(SirenSong song, {bool play = true}) async {
    if (_disposed) {
      return;
    }
    ++_songGeneration;
    _song = song;
    _selection = BasicSelection(kind: 'song', id: song.id);
    _syncDirectoryIndex(song);
    _phase = BasicPhase.detail;
    _loading = false;
    _error = '';
    _listPosition = _rowOfSelection(_selection).toDouble();
    if (!play) {
      _status = '已选中：${song.title}';
      _publish();
      return;
    }
    _status = '正在准备：${song.title}';
    if (_singlePlayAppend) {
      // 仅添加当前单曲：不替换队列（PlaybackQueue.selectTrack 会先找同曲目，
      // 找不到才追加到队尾），已有队列原样保留。
      _publish();
      _player.play(song.toTrack());
      return;
    }
    final List<SirenSong> source = _queueFor(song);
    final int index = source.indexWhere((SirenSong item) => item.id == song.id);
    _publish();
    _player.play(
      song.toTrack(),
      source: <Map<String, Object?>>[for (final SirenSong item in source) item.toTrack()],
      queueIndex: index < 0 ? null : index,
    );
  }

  /// 返回：歌词页回上一页；详情页回曲库；目录内回上一级
  /// （Qt/src/MusicDirectory.cpp:417-452 leaveDirectory(true)）；正在播放的歌不中断。
  Future<void> back() async {
    if (_disposed) {
      return;
    }
    if (_phase == BasicPhase.lyrics) {
      await closeLyrics();
      return;
    }
    if (_phase == BasicPhase.detail) {
      ++_detailGeneration;
      ++_songGeneration;
      _album = null;
      // 目录详情返回曲库：列号跟随目录 index 的 anchor（Qt selectDirectory 的 cell/8），
      // 否则在目录第 2 页点开的歌回到曲库时会停在别的列。
      _syncDirectoryLane();
      _phase = BasicPhase.library;
      _loading = false;
      _error = '';
      // 回曲库时滚动窗口跟着选中走（选中身份不变，Qt 的 libraryIndex 同义）。
      _listPosition = _rowOfSelection(_selection).toDouble();
      _status = _libraryStatus();
      _publish();
      return;
    }
    if (_phase == BasicPhase.library && _directory != null) {
      final BasicDirectory? parent = _leaveDirectory(restore: true);
      _loading = false;
      _error = '';
      _status = parent != null
          ? '$sirenReturnedPrefix${parent.title}'
          : '$sirenReturnedPrefix$sirenProviderLabel';
      _publish();
    }
  }

  /// 在资料库中打开当前 Siren 目录（archive 页的 'music:open-all-siren'，
  /// Qt MusicSiren 的“在资料库中打开”入口）：退出歌词/详情层、清空检索词、
  /// 回到完整曲库；正在播放的歌与队列不中断（队列权威始终是 [_player]）。
  ///
  /// 92 的 _onAction 没有这个 case：首页那枚『在资料库中打开 →』点了没反应。
  Future<void> openSirenLibrary() async {
    if (_disposed) {
      return;
    }
    _phaseBeforeLyrics = null;
    ++_detailGeneration;
    ++_songGeneration;
    _album = null;
    _directory = null;
    _query = '';
    _phase = BasicPhase.library;
    // 回到完整曲库：选中身份保留（可能在根列表里换行），滚动窗口重算。
    _listPosition = _rowOfSelection(_selection).toDouble();
    _loading = false;
    _error = '';
    _status = _catalogLoaded ? _catalogLoadedStatus() : sirenLibraryUnloadedStatus;
    _publish();
  }

  /// 打开 Siren 的「全部歌曲」虚拟目录（Qt/src/MusicSiren.cpp:193-246
  /// MusicLibrary::openSirenAllSongs 的移植）。
  ///
  /// 与 Qt 一致的三点：
  ///  - 只**选中**第一首（Qt :244-245 `next->index = 0; choose(next->songs.first())`），
  ///    不替换播放队列、不开始播放：真正播放要用户再点 '播放全部 →'
  ///    （basic_app 的 'music:play-loaded' → 首行 openSong），Qt 的 play() 也只在
  ///    用户按下播放时才 replaceQueue（Qt/src/MusicLibrary.cpp:943-957）。
  ///  - 目录 item 逐字照抄 Qt :205-218：provider / kind 'playlist' / virtual /
  ///    id 'siren-all' / key 'siren:playlist:all' / title '全部歌曲' /
  ///    description / trackCount / songs = lists[3] / ids / cursor=ids.size() / index 0。
  ///  - 曲库没加载成功时只上屏 '塞壬唱片曲库尚未加载'，不造空目录（Qt :194-197）。
  Future<void> openAllSirenSongs() async {
    if (_disposed) {
      return;
    }
    if (!_catalogLoaded || _catalogSongs.isEmpty) {
      _status = sirenLibraryUnloadedStatus;
      _publish();
      return;
    }
    _openAllSirenDirectory();
    _publish();
  }

  // ---------------------------------------------------------------------------
  // 列表选中 / 滚动 / 列切换（archive 手势与键盘的落点；一律不自动播放）
  // ---------------------------------------------------------------------------

  /// 选中列表第 [row] 行：只改选中与滚动窗口，不播放、不换队列。
  ///
  /// Qt 的 archive 点击只有 selectResult/selectDirectory（Qt/src/MusicDirectory.cpp:302-319）：
  /// 写 current/index/highlight 后回发 selectionRequested；play 是另一条路径
  /// （Qt/src/MusicLibrary.cpp:943-957 只在用户按播放时 replaceQueue）。
  Future<void> selectLibraryRow(int row) async {
    if (_disposed) {
      return;
    }
    final List<BasicListItem> items = basicLibraryItems(_state);
    if (items.isEmpty) {
      return;
    }
    final int index =
        row < 0 || row >= items.length ? basicSelectedItemIndex(_state, items) : row;
    _selectRow(items, index);
    _publish();
  }

  /// ↑/↓ 逐项选曲（Qt/src/MusicLibrary.cpp:646-668 MusicLibrary::next）：首尾环绕，
  /// 只移动选中并滚动窗口；不动 MusicPlayer、不起队列、不出声。
  Future<void> stepLibrarySelection(int direction) async {
    if (_disposed || direction == 0) {
      return;
    }
    final BasicDirectory? directory = _directory;
    if (directory != null) {
      // Qt MusicLibrary::next（Qt/src/MusicLibrary.cpp:646-650）在有目录时走
      // navigateDirectory(direction, "row")：同样先取模换 index，再由目录 anchor 折列。
      _navigateDirectoryBy(direction);
      return;
    }
    final List<BasicListItem> items = basicLibraryItems(_state);
    if (items.isEmpty) {
      return;
    }
    final int lane = _selectedLane;
    if (lane < 0 || lane >= _laneOffsets.length) {
      return;
    }
    final int count = items.length;
    // Qt/src/MusicLibrary.cpp:651-663（根列 next）：
    //   row = physicalSlots[lane].indexOf(selectedPhysical)  → 这里等价于 rowMemory[lane]
    //   absolute = wrap(offsets[lane] + row, count)
    //   next     = wrap(absolute + direction, count)
    //   target   = wrap(row + direction, 8)
    //   offsets[lane] = next - target      ← Qt 也允许为负
    // 这条入口与点击选中（selectResult 把 offsets 归一成 index/8*8）是**两条**入口：
    // 用 row%8 覆盖 rowMemory 会让边缘换行后的 open-all anchor 少一页
    // （lead 的 lane4 count10 反例：select9 后 next+1 应得 rowMemory=2/anchor=34，不是 32）。
    // `row` 是**物理行**（Qt `physicalSlots[lane].indexOf(selectedPhysical)`，8 个物理
    // 行恒存在），绝对不是条目下标，Qt 也从不按 count 夹它：夹成 count-1 会把短列表
    // 钉死在末行。反例（Qt/src/MusicLibrary.cpp:651-663，count=3 直接选第 0 条再连点
    // 四次 ↓）：正确 0,1,2,0,1（第 4 步 row=4、offsets=-3），夹 count 后变成 0,1,2,0,0。
    final int row = ((_rowMemory[lane] % 8) + 8) % 8;
    final int absolute = (((_laneOffsets[lane] + row) % count) + count) % count;
    final int next = ((absolute + direction) % count + count) % count;
    final int target = ((row + direction) % 8 + 8) % 8;
    _laneOffsets[lane] = next - target;
    _rowMemory[lane] = target;
    _selectRow(items, next, recordWindow: false);
    _publish();
  }

  /// 拖动结束：滚动窗口落到最近一行（[position] 单位是条目），只选中不播放。
  Future<void> commitLibraryScroll(double position) async {
    final List<BasicListItem> items = basicLibraryItems(_state);
    if (items.isEmpty) {
      return;
    }
    final double max = (items.length - 1).toDouble();
    final int row = position.isNaN ? 0 : position.clamp(0.0, max).round();
    await selectLibraryRow(row);
  }

  /// 列表拖动**过程中**的连续窗口位置（单位条目，可为小数）。
  ///
  /// 与 [commitLibraryScroll] 的分工就是 Qt 的 observe / select 分工：拖动中途只写
  /// 窗口（不选中、不播、不换队列），松手才由 commit 落行选中。写进 state.listPosition
  /// 之后，Qt 场景层（只读投影）在拖动期间就跟着一起滚，而不是等松手才动。
  void updateLibraryScroll(double position) {
    if (_disposed || position.isNaN || !position.isFinite) {
      return;
    }
    if ((position - _listPosition).abs() < 1e-4) {
      return;
    }
    _listPosition = position;
    _publish();
  }

  /// 3D 手势是否正在进行（`start` 之后、`commit` 之前）。
  ///
  /// 手势期间的"点选身份"回执必须丢掉：拖动松手与惯性落点不是同一条，谁先到都
  /// 不该改写列表选中，否则就是双消费（用户实测的"原地跳动一次"）。
  bool get nativeScrollActive => _nativeScrollOrigin != null;

  /// 详情页把唱片转到阈值以外：切到当前曲序里的相邻一张（[direction] = ±1）。
  ///
  /// 只换选中/详情，不播、不改队列——与 Qt 原始的"转到底翻一张"一致。
  Future<void> stepDetailFromScene(int direction) async {
    if (_disposed || _phase != BasicPhase.detail || direction == 0) {
      return;
    }
    final List<SirenSong> songs = _visibleSongs();
    if (songs.length < 2) {
      return;
    }
    final SirenSong? current = _song;
    final int index = current == null ? -1 : songs.indexWhere((SirenSong s) => s.id == current.id);
    final int next = index < 0 ? 0 : ((index + direction) % songs.length + songs.length) % songs.length;
    if (songs[next].id == current?.id) {
      return;
    }
    await openSong(songs[next], play: false);
  }

  /// 3D 归档点选落到列表行（手势进行中直接忽略，见 [nativeScrollActive]）。
  Future<void> selectCellFromScene(int row) async {
    // 第二道闸：只允许归档/曲库相位改选中。详情页/歌词页收到这种回执一律忽略
    // （与 stepDetailFromScene 的相位守卫对称），否则"转唱片"会静默换歌。
    if (_disposed || nativeScrollActive || _phase != BasicPhase.library) {
      return;
    }
    await selectLibraryRow(row);
  }

  /// Qt 3D 场景回写的 archive 连续滚动（条目增量，可为小数；见 NativeScene 的滚动出口）。
  ///
  /// 三个约束都来自 Qt 原始语义与用户 m01597 的补充：
  ///  - 只动**当前列**的窗口：3D 手势不换所属列（换列只有显式 HUD ←/→）。
  ///  - 松手（[committed]）才落行选中；中途只滚窗口，桌面惯性与选中都不被改写。
  ///  - [started] 记下序列起点，之后同一位置回写被 `1e-4` 门限吃掉，不会回声。
  void applyNativeArchiveScroll(
    double deltaRows, {
    bool committed = false,
    bool started = false,
  }) {
    if (_disposed || deltaRows.isNaN || !deltaRows.isFinite) {
      return;
    }
    final List<BasicListItem> items = basicLibraryItems(_state);
    if (items.isEmpty) {
      _nativeScrollOrigin = null;
      return;
    }
    if (started || _nativeScrollOrigin == null) {
      _nativeScrollOrigin = _listPosition;
    }
    final double max = (items.length - 1).toDouble();
    final double next = ((_nativeScrollOrigin ?? _listPosition) + deltaRows).clamp(0.0, max);
    if (committed) {
      _nativeScrollOrigin = null;
      unawaited(commitLibraryScroll(next));
      return;
    }
    if ((next - _listPosition).abs() < 1e-4) {
      return;
    }
    _listPosition = next;
    _publish();
  }

  /// ←/→：Qt/src/NativeHudController.cpp:650-662 的两条分支，逐条照抄。
  ///
  ///  - 有目录 → `music.navigateDirectory(next ? 8 : -8)`（Qt/src/MusicDirectory.cpp:321-344）：
  ///    按 8 格换"列"，**始终取模环绕**。第一行再往左不是"返回"，而是绕到末尾那一页——
  ///    返回只有显式 back/music:parent（Qt/src/NativeHud.cpp:378-410 的『← 返回上一级』）。
  ///  - 无目录 → `sources = music.sourceOrder(); music.showSource(sources.at(wrap(index ± 1,
  ///    sources.size())))`：在五列之间循环换列，不做"打开目录"、也不做 no-op。
  Future<void> navigateColumn(int direction) async {
    if (_disposed || direction == 0) {
      return;
    }
    if (_directory != null) {
      _navigateDirectoryBy(direction > 0 ? 8 : -8);
      return;
    }
    _showSourceLane(basicStepSourceLane(_selectedLane, direction));
  }

  /// 目录内 ±8 换页（Qt MusicDirectory::navigateDirectory，Qt/src/MusicDirectory.cpp:321-344）：
  /// `selectDirectory(((target % count) + count) % count, ...)` —— 始终取模，没有"到头就返回"。
  void _navigateDirectoryBy(int step) {
    final BasicDirectory? directory = _directory;
    if (directory == null) {
      return;
    }
    final List<SirenSong> songs = directory.songs;
    if (songs.isEmpty) {
      return;
    }
    final int current =
        directory.index < 0 || directory.index >= songs.length ? 0 : directory.index;
    final int next = ((current + step) % songs.length + songs.length) % songs.length;
    final SirenSong song = songs[next];
    // Qt MusicDirectory::selectDirectory（Qt/src/MusicDirectory.cpp:302-319）：
    // 先落 index，再用**目录自己的 anchor** 折列 ——
    //   cell = (index + anchor) % 40; selectedLane = cell / 8
    // anchor 是「页起点在 5×8 网格里的折列偏移」（updateSongs，:21-31），由
    // openSirenAllSongs 设成 destination*8 + rowMemory[destination]；它不是物理槽，
    // 也不能用 index % 40 顶替（那样一打开就换错列）。
    final BasicDirectory updated = directory.copyWith(index: next);
    _directory = updated;
    _song = song;
    _selection = BasicSelection(kind: 'song', id: song.id);
    _selectedLane = updated.laneAt(next);
    _listPosition = next.toDouble();
    // 目录内的页内行列号是目录自己的 index/anchor，不写进根列的 rowMemory/lanePositions
    // （Qt 的 rowMemory/offsets 只服务根列；目录用 directory->index）。否则退出目录时
    // 会把目录行号当成根列滚动位置恢复。
    _status = '已选中：${song.title}';
    _publish();
  }

  /// 让 [selectedLane] 跟上目录当前 index（Qt selectDirectory 的 `cell / 8`）。
  ///
  /// 目录里任何一次"落 index 后写回 selectedLane"的路径都必须走它，否则会留下
  /// index 与列各说各话的状态。没有目录时是 no-op。
  void _syncDirectoryLane() {
    final BasicDirectory? directory = _directory;
    if (directory == null) {
      return;
    }
    _selectedLane = directory.laneAt(directory.index);
  }

  /// 换列（Qt MusicLibrary::showSource，Qt/src/MusicLibrary.cpp:556-580）：
  /// 写 selectedLane、恢复该列记住的行、**只选中不播放**；列为空时诚实空态。
  ///
  /// 与 Qt 的差异只有一处并已在报告登记：Qt 会为 lane 1/2 走 loadSirenSource
  /// （本机 likedIDs / playlists，见 Qt/src/MusicSiren.cpp:251-335），基础版没有本机
  /// 集合的实现，所以这两列在端口为 null 时上屏「本地集合暂不可用」而不是发请求；
  /// 端口注入后投影的是真实本机数据，空才是真的空。
  void _showSourceLane(int lane) {
    if (lane < 0 || lane >= basicSirenColumns.length) {
      return;
    }
    _selectedLane = lane;
    final List<BasicListItem> items = basicLibraryItems(_probeState());
    if (items.isEmpty) {
      _selection = null;
      _song = null;
      _listPosition = 0;
      _lanePositions[lane] = 0;
      _status = basicLaneEmptyNotice(
        lane,
        localCollectionsAvailable: _localCollectionsAvailable,
        unresolvedLikedIds: _localUnresolvedLikedIds,
      );
      _publish();
      return;
    }
    // Qt showSource（Qt/src/MusicLibrary.cpp:566-573）恢复的是**滚动窗口的那一行**：
    //   physical = physicalSlots[lane].value(rowMemory[lane]); observe(physical)
    //   → 绝对行 = wrap(offsets[lane] + rowMemory[lane], count)
    // 不是“上次记住的选中身份”（那个可能已被 openSong/step 挪到别的窗口行）。
    final int count = items.length;
    final int row = (((_laneOffsets[lane] + _rowMemory[lane]) % count) + count) % count;
    // Qt showSource（Qt/src/MusicLibrary.cpp:556-580）只恢复 selectedPhysical/observe，
    // 不改 offsets/rowMemory —— 恢复一条记忆不能把该列的滚动窗口重算成 row%8。
    _selectRow(items, row, recordWindow: false);
    _status = '${basicLaneName(lane)}：${items.length} 项';
    _publish();
  }

  /// 把一行变成当前选中：只写选中身份与目录高亮，不碰 [_player]。
  ///
  /// 专辑行只改选中身份，不打开详情（Qt 的 selectResult(..., highlightOnly) 不改 mode）；
  /// 详情由 'open' 路径（[openSong]/openAlbum）负责。
  void _selectRow(
    List<BasicListItem> items,
    int row, {
    bool recordWindow = true,
    bool announce = true,
  }) {
    final BasicListItem item = items[row];
    final BasicSelection? selection = basicItemSelection(_state, item);
    if (selection != null) {
      _selection = selection;
      if (selection.isSong) {
        // 歌曲行的下标指回哪份列表随相位变（与 [_openAt] 同一份真值）：
        // 专辑详情 → album.songs；其余 → 当前可见列表（目录/筛选/全部歌曲）。
        final SirenAlbum? album = _state.album;
        final List<SirenSong> tracks = (_phase == BasicPhase.detail && album != null)
            ? album.songs
            : _visibleSongs();
        final SirenSong? song = item.index >= 0 && item.index < tracks.length
            ? tracks[item.index]
            : _songById[selection.id];
        if (song != null) {
          _song = song;
          _syncDirectoryIndex(song);
        }
      } else {
        // Qt MusicLibrary::choose 对非 song 会整体换 current；基础版把 current 拆成
        // selection + song，专辑行必须清掉旧曲目，否则 `BasicViewState.song` 在专辑列
        // 仍指上一首，`music:play`（basic_app 走 `openSong(state.song)`）会播到旧歌。
        _song = null;
      }
    }
    _listPosition = row.toDouble();
    if (_directory == null && _selectedLane >= 0 && _selectedLane < _rowMemory.length) {
      // Qt MusicLibrary::observe（Qt/src/MusicLibrary.cpp:262-268）：root 列里选中一行时
      // 写 `rowMemory[selectedLane] = 页内行`（0..7）。openSirenAllSongs 用它拼目录
      // anchor（Qt/src/MusicSiren.cpp:239-240）；目录内部不写 rowMemory
      // （observeDirectory 只折 anchor，Qt/src/MusicDirectory.cpp:255-300）。
      if (recordWindow) {
        // Qt MusicLibrary::selectResult（Qt/src/MusicLibrary.cpp:616-643）：
        //   offsets[lane] = viewIndex / 8 * 8;  rowMemory[lane] = viewIndex % 8
        _laneOffsets[_selectedLane] = row ~/ 8 * 8;
        _rowMemory[_selectedLane] = row % 8;
      }
      // 根列的"上次选中/滚动位置"只属于根列：目录里的行号与根列不是同一套坐标，
      // 写进去会让退出目录时把目录行号当根列位置恢复。
      _lanePositions[_selectedLane] = _listPosition;
    }
    if (announce) {
      _status = '已选中：${item.title}';
    }
  }

  /// 当前选中身份对应的列表行号（探针状态只为复用同一份列表真值）。
  int _rowOfSelection(BasicSelection? selection) {
    final BasicViewState probe = _probeState(selection: selection);
    final List<BasicListItem> items = basicLibraryItems(probe);
    return basicSelectedItemIndex(probe, items);
  }

  /// 打开歌词页（Qt 的模态歌词面板语义；没有当前曲目时不打开）。
  Future<void> openLyrics() async {
    if (_disposed || _song == null) {
      return;
    }
    if (_phase != BasicPhase.lyrics) {
      _phaseBeforeLyrics = _phase;
      _phase = BasicPhase.lyrics;
      _publish();
    }
  }

  /// 关闭歌词页，回到打开前的页面。
  Future<void> closeLyrics() async {
    if (_disposed || _phase != BasicPhase.lyrics) {
      return;
    }
    _phase = _phaseBeforeLyrics ?? BasicPhase.library;
    _phaseBeforeLyrics = null;
    _publish();
  }

  /// 播放/暂停；没有播放中的曲目时从当前选中的歌开始。
  /// 系统 PLAY：幂等。已经在播就不动（不得变成暂停）。
  @override
  Future<void> play() async {
    if (_disposed || _audio.state.playing) {
      return;
    }
    await togglePlay();
  }

  /// 系统 PAUSE：幂等。已经暂停就不动。
  @override
  Future<void> pause() async {
    if (_disposed || !_audio.state.playing) {
      return;
    }
    await togglePlay();
  }

  /// 把真实在播身份 + 真实 audio 读数报给系统媒体控件。
  ///
  /// 身份只来自 [_playingTrackOf]（真实 audio 对应曲目），不是 UI 选中行；
  /// 封面走 [_requestArtwork] 的本地落盘结果：只有在**当前播放身份**仍然是这首时
  /// 才把路径写进通知，绝不把远端 URL 交给 Kotlin 的 decodeFile。
  void _syncMediaSession() {
    final BasicMediaSessionAdapter? media = _mediaSession;
    if (media == null || _disposed) {
      return;
    }
    final SirenSong? track = _playingTrackOf();
    if (track == null) {
      // 没有在播身份就是"没有封面"：连带把上一首的落盘路径作废，避免复用时串台。
      _artTrackId = '';
      _artUrl = '';
      _artPath = '';
      _artAttempts = 0;
      unawaited(media.sync(identity: null, audio: _audio.state));
      return;
    }
    // 先按当前 (id, url) 归位封面状态，再决定这次上报贴不贴图。
    // 反过来的话，同一身份把封面 URL 换成空时，这一次上报仍会把旧图带出去
    // （LEAD 2026-11-16 的 M1 反例）。
    _requestArtwork(track);
    final bool artMatches =
        _artTrackId == track.id && _artUrl == track.cover.trim();
    final String cover = artMatches ? _artPath : '';
    unawaited(media.sync(
      identity: BasicMediaIdentity(
        id: track.id,
        title: track.title,
        artist: track.artist,
        album: track.album,
        coverFilePath: cover,
      ),
      audio: _audio.state,
    ));
  }

  /// 把当前播放曲目的远端封面落成本地文件，成功后补一次上报。
  ///
  /// 三条护栏，专治 A→B→A 的迟到结果：
  ///  1. 同一 (id, url) 只请求一次——本方法由 [_publish] 高频调用，不能每次重抓；
  ///  2. 缓存代次：每次新请求 [_artCache.beginGeneration]，回来的结果代次不是最新就丢弃；
  ///  3. 身份复核：真正落值前再确认"当前在播的仍是这首"，否则丢弃（回到 A 后，
  ///     B 的迟到结果既过不了代次也过不了身份）。
  ///
  /// 失败（没有目录 / 404 / 超时）一律留空封面：通知没有封面不是播放错误。
  void _requestArtwork(SirenSong track) {
    final BasicArtCache? cache = _artCache;
    if (cache == null || _disposed) {
      return;
    }
    final String url = track.cover.trim();
    final bool same = track.id == _artTrackId && url == _artUrl;
    if (!same) {
      // 换曲或换 URL（包括"换成空"都是一次状态切换）：必须在这里就作废在飞结果，
      // 并且必须早于下面任何 early return —— 否则同一个 (id, url) 的旧闭包
      // 会带着相同代次回来，把旧图写进一个已经该显示空封面的身份。
      _artTrackId = track.id;
      _artUrl = url;
      _artPath = '';
      _artAttempts = 0;
      _artInFlight = -1;
      cache.beginGeneration();
    }
    if (url.isEmpty) {
      // 空 URL 的结论就是"没有封面"：_syncMediaSession 紧接着会如实上报空字符串。
      return;
    }
    if (_artPath.isNotEmpty) {
      return;
    }
    if (_artAttempts >= _artMaxAttempts) {
      return;
    }
    if (_artInFlight >= 0) {
      // 已经有同一 (id, url) 的请求在飞：不要再建闭包，否则失败会被重复记账。
      return;
    }
    final int generation = cache.generation;
    _artInFlight = generation;
    _artAttempts += 1;
    final String requestUrl = url;
    unawaited(() async {
      // 封面永远不是播放错误：目录缺失、读盘、落盘、上报里的任何异常都在这里
      // 咽掉并留空封面，绝不让一个未处理的 zone error 打到 debug 红屏。
      try {
        final String? path = await cache.localPath(requestUrl);
        if (_artInFlight == generation) {
          // 归还在飞名额（无论成功失败）：只有真正拥有这个名额的那次请求才还。
          _artInFlight = -1;
        }
        if (_disposed) {
          return;
        }
        if (generation != cache.generation) {
          return;
        }
        if (_artTrackId != track.id || _artUrl != requestUrl) {
          return;
        }
        if (_playingTrackOf()?.id != track.id) {
          return;
        }
        if (path == null || path.isEmpty) {
          // 这次抓取失败：额度已在发请求时记过，这里只留空，
          // 下一次上报才允许重试（上限 _artMaxAttempts）。
          _artPath = '';
          return;
        }
        _artPath = path;
        // 只有真的落了盘才补一次上报（失败留空的结论已经由上面那次 sync 送出）。
        _syncMediaSession();
      } catch (_) {
        if (_artInFlight == generation) {
          // localPath 自己承诺不抛，但真抛了也不能把在飞名额永久占住。
          _artInFlight = -1;
        }
        _artPath = '';
      }
    }());
  }

  Future<void> togglePlay() async {
    if (_disposed) {
      return;
    }
    if (_player.current.isEmpty) {
      final SirenSong? song = _song;
      if (song == null) {
        return;
      }
      await openSong(song);
      return;
    }
    _player.toggle();
    _publish();
  }

  /// 按比例定位（0..1）：命令下发给 native，位置由 native 回报，绝不在这里推算。
  Future<void> seekToFraction(double fraction) async {
    if (_disposed || _player.current.isEmpty) {
      return;
    }
    final double clamped = fraction.isNaN ? 0 : fraction.clamp(0.0, 1.0).toDouble();
    final double duration = _number(_player.state['duration']);
    final bool seekable = _player.state['seekable'] == true;
    _player.seek(clamped);
    final LyricsController? lyrics = _lyrics;
    if (seekable && duration > 0 && lyrics != null) {
      // seek 后立即按目标位置重算活动行；目标位置来自 native 报的真实时长。
      lyrics.sync(clamped * duration);
    }
    _publish();
  }

  /// 下一首（队列由 MusicPlayer::next 推进，音源由引擎 fresh 读取）。
  Future<void> next() async {
    if (_disposed) {
      return;
    }
    _player.next(1);
    _publish();
  }

  /// 上一首。
  Future<void> previous() async {
    if (_disposed) {
      return;
    }
    _player.next(-1);
    _publish();
  }

  /// 测试钩子：注入一拍时间，走 Timer.periodic 完全相同的链路。
  ///
  /// 生产 ticker 是 100ms 的真实 Timer；测试里 Timer 不会自己走，所以留这一个入口。
  /// 它只调用 MusicPlayer.tick / LyricsController.tick，不产生任何进度。
  @visibleForTesting
  /// 测试用的**单链路** tick 替身（生产由 100ms Timer 喂 [_clock] 的 elapsed）。
  ///
  /// tick 的 time 是"单调秒数"绝对值，测试里写成从 0 起的相对脚本时间（0.2、0.3…）；
  /// 生产 ticker 也在同一轴上真跑（boot 起每 100ms 一次，值 ≈0.1…），两者会互相把对方
  /// 挡在 0.1 秒闸门外。这里整体加一个远离真实 elapsed 的常量偏移，让脚本时间保持单调
  /// 且始终在 ticker 之上——节流语义（0.1 秒一次）与零点都按测试意图生效。
  void pumpForTest(double seconds) => _pump(seconds + 600.0);

  @override
  void dispose() {
    if (_disposed) {
      return;
    }
    _disposed = true;
    _ticker?.cancel();
    _ticker = null;
    _catalogRetryTimer?.cancel();
    _catalogRetryTimer = null;
    _clock.stop();
    _player.removeListener(_onPlayerChanged);
    _lyrics?.removeListener(_onLyricsChanged);
    _audio.removeListener(_onAudioStateChanged);
    unawaited(_mediaSession?.dispose() ?? Future<void>.value());
    _mediaSession = null;
    // 封面缓存的关闭与媒体适配器的释放彼此独立：前者失败不影响后者，
    // 反之亦然（都只是资源，不该把 dispose 变成会抛的路径）。
    final BasicArtCache? artCache = _artCache;
    _artCache = null;
    if (artCache != null) {
      unawaited(artCache.close());
    }
    if (_ownsRepository) {
      _repository.close();
    }
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // 曲库
  // ---------------------------------------------------------------------------

  Future<void> _loadCatalog() async {
    final int generation = ++_catalogGeneration;
    _catalogLoaded = false;
    _loading = true;
    _error = '';
    _status = _catalogRetries > 0
        ? '$sirenCatalogLoadingStatus（重试 $_catalogRetries/$maxCatalogRetries）'
        : sirenCatalogLoadingStatus;
    _phase = BasicPhase.boot;
    _publish();
    try {
      final SirenCatalog catalog = await _repository.loadCatalog();
      if (generation != _catalogGeneration) {
        // 迟到的曲库：整份丢弃，且不改 loading——Qt 的回调只在 valid 通过时才把
        // sirenCatalogLoading 复位（Qt/src/MusicSiren.cpp:52-56）。
        return;
      }
      _catalogSongs = catalog.songs;
      _catalogAlbums = catalog.albums;
      _songById = <String, SirenSong>{
        for (final SirenSong song in catalog.songs) song.id: song,
      };
      // 本机集合的歌曲 id 要经曲库解析成行；曲库到位后重新投影一次
      // （Qt/src/MusicSiren.cpp:296-335 也是把 likedIDs 交给 api 取 songs）。
      _refreshLocalCollections();
      _catalogLoaded = true;
      _loading = false;
      _error = '';
      _catalogRetries = 0;
      _catalogRetryTimer?.cancel();
      _catalogRetryTimer = null;
      _status = _catalogLoadedStatus();
      _phase = BasicPhase.library;
      // 冷启动默认选中：Qt 打开资料库时 MusicLibrary 里本来就有一条 current，
      // 3D 场景靠它拿到 current{kind,id,key,cover} 才会 loadCover 并画出封面。
      // 少了这一步，场景只收到 index=-1/count=936/key=（真机 06:28:28 日志），
      // 于是永远没有 cover 请求 —— 这正是用户 P0 #2「封面还是不加载」的根因。
      _publish();
      if (_selection == null) {
        _selectInitialRow();
      }
    } on Object catch (error) {
      if (generation != _catalogGeneration) {
        return;
      }
      _loading = false;
      _catalogLoaded = false;
      _error = _messageOf(error);
      _status = sirenCatalogFailurePrefix + _error;
      _phase = BasicPhase.library;
      _scheduleCatalogRetry();
    }
    _publish();
  }

  /// 冷启动/重试后的默认选中：取当前列第一条可见行（Qt 首个物理槽的等价物）。
  ///
  /// 只在「曲库刚到位且还没有选中」时调用，不覆盖用户已有选中，也不播放。
  void _selectInitialRow() {
    final List<BasicListItem> items = basicLibraryItems(_state);
    if (items.isEmpty) {
      return;
    }
    // announce:false —— 首屏那句话仍然是"曲库已加载：N 首 / M 张专辑"，不能一进页面
    // 就被"已选中：…"盖掉（那不是用户做的动作，藏掉曲库规模反而是信息损失）。
    _selectRow(items, 0, announce: false);
    _publish();
  }

  /// 曲库失败的有界自动重试（400/800/1600ms），状态文案如实写第几次。
  ///
  /// Qt 侧没有这条路径（失败就停在失败态），但用户看到的是「首页永远空」；
  /// 这里保持真实 loading/error/retry 语义，不造假数据、不换第二个 backend。
  void _scheduleCatalogRetry() {
    if (_disposed || _catalogLoaded || _catalogRetries >= maxCatalogRetries) {
      return;
    }
    _catalogRetries += 1;
    final int attempt = _catalogRetries;
    // 失败文案保持**原文**（失败原因不被追加词污染）；"正在重试第几次"由下一轮
    // _loadCatalog 的 loading 文案如实给出。
    _catalogRetryTimer?.cancel();
    _catalogRetryTimer = Timer(Duration(milliseconds: 400 * (1 << (attempt - 1))), () {
      if (_disposed || _catalogLoaded || !_booted) {
        return;
      }
      unawaited(_loadCatalog());
    });
  }

  String _catalogLoadedStatus() {
    return '$sirenCatalogLoadedPrefix${_catalogSongs.length} 首 / ${_catalogAlbums.length} 张专辑';
  }

  /// 资料库层的状态文案：目录打开时是目录标题（Qt MusicLibrary::libraryName()，
  /// Qt/src/MusicLibrary.cpp:189-194），否则是曲库加载结果。
  String _libraryStatus() {
    final BasicDirectory? directory = _directory;
    if (directory != null) {
      return '$sirenOpenedPrefix${directory.title}';
    }
    return _catalogLoaded ? _catalogLoadedStatus() : sirenLibraryUnloadedStatus;
  }

  /// 「全部歌曲」目录的 state 投影（Qt/src/MusicSiren.cpp:205-246）。
  ///
  /// Qt 用 lists[3]（全部已加载曲目）填 songs，ids 是同一份顺序；
  /// parent 记下打开前的目录，供 leaveDirectory(true) 逐级返回（Qt :221-223）。
  void _openAllSirenDirectory() {
    ++_detailGeneration;
    ++_songGeneration;
    final List<SirenSong> songs = _catalogSongs;
    _directory = BasicDirectory(
      provider: sirenProvider,
      kind: 'playlist',
      id: sirenAllSongsId,
      key: sirenAllSongsKey,
      title: sirenAllSongsTitle,
      artist: sirenProviderLabel,
      cover: songs.first.cover,
      description: sirenAllSongsDescription,
      trackCount: songs.length,
      virtual: true,
      songs: songs,
      ids: <String>[for (final SirenSong song in songs) song.id],
      cursor: songs.length,
      index: 0,
      parent: _directory,
      // Qt 目录 item 记下打开前的列与选中（MusicDirectory.cpp:417-447 parentLane/parentItem）。
      parentLane: _selectedLane,
      parentSelection: _selection,
      // Qt/src/MusicSiren.cpp:236-240：`destination=(selectedLane+1)%5;
      // next->anchor = destination*8 + rowMemory[destination]`。anchor 是"页起点在
      // 5×8 网格里的折列偏移"，之后每一次 selectDirectory 都用它折列；这里存下来，
      // 不在这里改 selectedLane（open 本身不 selectDirectory）。
      anchor: _directoryAnchorFor(_selectedLane),
    );
    _album = null;
    _phase = BasicPhase.library;
    _loading = false;
    _error = '';
    _status = '$sirenOpenedPrefix$sirenAllSongsTitle';
    // Qt :243-245：current 清空后 choose(lists[3].first())——只选中，不播放。
    _song = songs.first;
    _selection = BasicSelection(kind: 'song', id: songs.first.id);
    _listPosition = 0;
    // Qt/src/MusicSiren.cpp:236-243 的 openSirenAllSongs **不调用 selectDirectory**：
    // 它只设 `next->anchor = destination*8 + rowMemory[destination]`（destination=(3+1)%5=4）
    // 并发 `navigationRequested("lane", 1)`——那是 3D 场景镜头，不是资料库列。
    // 所以 HUD 首帧的列号保持原来的 selectedLane（Qt NativeHud.cpp:482-490 画
    // `TRACK COLUMN pad(selectedLane+1)` = 04 / 05），这里不能重算成 cell/8。
    // 目录内的 ±8 / 点击才走 anchor 折算（_navigateDirectoryBy / _syncDirectoryIndex，
    // 对应 Qt selectDirectory Qt/src/MusicDirectory.cpp:302-319）。
  }

  /// Qt `openSirenAllSongs` 的目录锚点（Qt/src/MusicSiren.cpp:236-240）：
  /// `destination = (selectedLane + 1) % 5; anchor = destination*8 + rowMemory[destination]`。
  ///
  /// rowMemory 在这里是**逻辑页内行**（0..7）；基础版没有 physicalSlots，所以不能把它
  /// 当成物理槽号写进任何 native 契约。
  int _directoryAnchorFor(int lane) {
    final int destination = (lane + 1) % basicSirenColumns.length;
    return destination * 8 + _rowMemory[destination];
  }

  /// 退出目录（Qt/src/MusicDirectory.cpp:417-452 leaveDirectory）：restore=true 回父目录并
  /// 用父目录记录的 index 重新选中（Qt :449 selectDirectory(parent->index)），
  /// restore=false 直接回资料库根（搜索结束时的 showSource(0)）。
  BasicDirectory? _leaveDirectory({required bool restore}) {
    final BasicDirectory? leaving = _directory;
    ++_detailGeneration;
    ++_songGeneration;
    if (!restore) {
      _directory = null;
      return null;
    }
    final BasicDirectory? parent = leaving?.parent;
    _directory = parent;
    // Qt/src/MusicDirectory.cpp:431-435：`selectedLane = folder->parentLane;
    // selectedPhysical = folder->parentPhysical; current = folder->parentItem`——
    // 返回资料库时列和选中都回到打开目录之前的那个。
    if (leaving != null) {
      _selectedLane = leaving.parentLane;
      final BasicSelection? restored = leaving.parentSelection;
      _selection = restored;
      if (restored != null && restored.isSong) {
        _song = _resolveSongById(restored.id);
      } else {
        // Qt leaveDirectory(true) 的 `current = folder->parentItem`：parentItem 不是曲目
        // （专辑/歌单行）或根本没有时，不能把目录里那首歌留成 state.song——否则随后的
        // `music:play` 会播到一首已经离开视图的歌（与 _selectRow 的非 song 规则一致）。
        _song = null;
      }
    }
    if (parent != null && parent.songs.isNotEmpty) {
      final int index =
          parent.index < 0 || parent.index >= parent.songs.length ? 0 : parent.index;
      _song = parent.songs[index];
      _selection = BasicSelection(kind: 'song', id: _song!.id);
      // Qt :449 `selectDirectory(directory->index)`：父目录自己的 anchor 折算停留列
      // （`cell = (index+anchor)%40; lane = cell/8`），不是简单沿用 parentLane。
      _selectedLane = parent.laneAt(index);
      _listPosition = _rowOfSelection(_selection).toDouble();
    } else {
      _listPosition = _lanePositions[_selectedLane];
    }
    _lanePositions[_selectedLane] = _listPosition;
    return parent;
  }

  /// 目录内选曲时同步高亮位置（Qt/src/MusicDirectory.cpp:302-319 selectDirectory：
  /// 先把 directory->index 写成被点行，再 choose 该项）。
  ///
  /// 写完 index 必须立刻用目录 anchor 折算 selectedLane（`cell = (index+anchor)%40;
  /// lane = cell/8`），否则点击落在第 2 页的曲目时目录高亮列会停在旧列。
  void _syncDirectoryIndex(SirenSong song) {
    final BasicDirectory? directory = _directory;
    if (directory == null) {
      return;
    }
    final int index =
        directory.songs.indexWhere((SirenSong item) => item.id == song.id);
    if (index < 0) {
      return;
    }
    if (index != directory.index) {
      _directory = directory.copyWith(index: index);
    }
    _selectedLane = _directory!.laneAt(index);
  }

  /// 重新查询本机集合（Qt reloadSirenCollections，Qt/src/MusicSiren.cpp:6-21）。
  ///
  /// 只读：likedIds → 曲库解析成行（解析不到的 id 不造行），playlists → 行投影。
  /// 端口为 null（当前生产事实）或查询抛错时保持「不可用」，绝不把没查询过说成空库：
  /// 这两件事在界面上是两句不同的话（[basicLaneEmptyNotice]）。
  void _refreshLocalCollections() {
    final BasicLocalCollections? collections = _collections;
    if (collections == null) {
      _localCollectionsAvailable = false;
      _localUnresolvedLikedIds = 0;
      _likedSongs = const <SirenSong>[];
      _localPlaylists = const <BasicLocalPlaylist>[];
      return;
    }
    try {
      final List<SirenSong> liked = <SirenSong>[];
      final Set<String> seen = <String>{};
      int unresolved = 0;
      for (final String id in collections.likedIds()) {
        final SirenSong? song = _resolveSongById(id);
        if (song != null && seen.add(id)) {
          liked.add(song);
        } else if (song == null && seen.add(id)) {
          // 源集合里确实有这个 id，但曲库还没解析出来（Qt 会拿 id 再请求 songs，
          // Qt/src/MusicSiren.cpp:296-322）。这里不造 SirenSong，只保留“还没对上”的事实。
          unresolved += 1;
        }
      }
      final List<BasicLocalPlaylist> playlists = collections.playlists();
      _likedSongs = List<SirenSong>.unmodifiable(liked);
      _localPlaylists = List<BasicLocalPlaylist>.unmodifiable(playlists);
      _localUnresolvedLikedIds = unresolved;
      _localCollectionsAvailable = true;
    } on Object {
      // 本机集合读不出来就是一个可上屏的事实（“暂不可用”），不让它拖垮曲库页。
      _localCollectionsAvailable = false;
      _localUnresolvedLikedIds = 0;
      _likedSongs = const <SirenSong>[];
      _localPlaylists = const <BasicLocalPlaylist>[];
    }
  }

  /// 按 id 找一首真曲目：详情/播放过的缓存优先，其次整份曲库，最后当前目录/可见列表。
  ///
  /// [_songById] 只装详情页/播放过的歌曲（:326/:1165 两处写入），曲库里没点开过的歌
  /// 不在里面；只靠它还原选中，会把「返回资料库」「喜欢的歌曲」这类仅有 id 的路径
  /// 静默变成 null/0——曲库里明明有这首歌。Qt 侧对应的是整份曲目表先查缓存再回落
  /// （MusicDirectory.cpp:417-452 的 `details.value(key, folder->parentItem)`）。
  SirenSong? _resolveSongById(String id) {
    if (id.isEmpty) {
      return null;
    }
    final SirenSong? cached = _songById[id];
    if (cached != null) {
      return cached;
    }
    for (final SirenSong song in _catalogSongs) {
      if (song.id == id) {
        return song;
      }
    }
    final BasicDirectory? directory = _directory;
    if (directory != null) {
      for (final SirenSong song in directory.songs) {
        if (song.id == id) {
          return song;
        }
      }
    }
    for (final SirenSong song in _visibleSongs()) {
      if (song.id == id) {
        return song;
      }
    }
    return null;
  }

  List<SirenSong> _visibleSongs({int? lane}) {
    final int selected = lane ?? _selectedLane;
    final BasicDirectory? directory = _directory;
    if (directory != null) {
      // Qt/src/MusicLibrary.cpp:212-214：`directory ? directory->orderedSongs() : …`。
      // sortField 默认 'none'（MusicDirectory.cpp:9-19），顺序就是 songs 原序。
      return directory.songs;
    }
    if (_phase == BasicPhase.detail && _album != null) {
      return _album!.songs;
    }
    if (selected == basicSearchLane) {
      // 「搜索结果」列只列本次检索命中的曲目（Qt lists[0]）。
      return filterSirenSongs(_catalogSongs, _query);
    }
    if (selected == 1) {
      // 「喜欢的歌曲」列：本机 likedIDs 经曲库解析出的曲目（Qt lists[1]）。
      return _likedSongs;
    }
    if (selected == 2) {
      // 「我的歌单」列的行是歌单（state.localPlaylists），这一列里没有曲目：
      // 不能把整库曲目塞进 state.songs，否则 state.song/播放面会指到不相干的曲目。
      return const <SirenSong>[];
    }
    return _catalogSongs;
  }

  List<SirenAlbum> _visibleAlbums({int? lane}) {
    final int selected = lane ?? _selectedLane;
    if (_directory != null) {
      // 目录里只列曲目（Qt libraryItems() 的 directory 分支），专辑行不再出现。
      return const <SirenAlbum>[];
    }
    if (_phase == BasicPhase.detail && _album != null) {
      return const <SirenAlbum>[];
    }
    if (selected == basicSearchLane) {
      return filterSirenAlbums(_catalogAlbums, _query);
    }
    return _catalogAlbums;
  }

  /// 五列的条目表（Qt 40 格语义槽位的来源），带签名缓存。
  ///
  /// 拖动时每帧都会 _publish，而整库有 936 首；每次重建 5 列列表会拖垮帧率。
  /// 这里按「会影响列内容的东西」缓存：曲库代际、检索词、目录身份、页面、专辑、列。
  /// 收藏/歌单的**内容**签名。
  ///
  /// 只数长度抓不到「同长度替换」（一首收藏换另一首、歌单里换一首歌但 trackCount 不变），
  /// 那样 [_laneItemTable] 会命中旧缓存，把旧行对象继续发出去，场景身份/epoch 也就不会
  /// 因真实内容变化而递增（ORIGIN-LIFECYCLE-153 的 apiAsks.for152_noSourceWritesBy153[0]）。
  String _collectionsDigest() {
    final StringBuffer buffer = StringBuffer();
    for (final SirenSong song in _likedSongs) {
      buffer
        ..write(song.id)
        ..write(',');
    }
    buffer.write('|');
    for (final BasicLocalPlaylist playlist in _localPlaylists) {
      buffer
        ..write(playlist.id)
        ..write(':')
        ..write(playlist.title)
        ..write(':')
        ..write(playlist.trackCount)
        ..write(',');
    }
    return _fnv1a64(buffer.toString());
  }

  /// FNV-1a 64：只用来给缓存签名做稳定的短摘要，不参与任何真值判断。
  static String _fnv1a64(String value) {
    int hash = 0xcbf29ce484222325;
    for (final int unit in value.codeUnits) {
      hash = (hash ^ unit) * 0x100000001b3;
      hash &= 0xFFFFFFFFFFFFFFFF;
    }
    return hash.toRadixString(16).padLeft(16, '0');
  }

  List<List<BasicListItem>> _laneItemTable() {
    final String signature = <Object?>[
      _catalogGeneration,
      _query,
      _directory?.id ?? '',
      _phase.name,
      _album?.id ?? '',
      _collectionsDigest(),
      _localCollectionsAvailable,
    ].join('|');
    if (signature == _laneItemsSignature && _laneItemsCache != null) {
      return _laneItemsCache!;
    }
    final List<List<BasicListItem>> table = <List<BasicListItem>>[
      for (int lane = 0; lane < basicSirenColumns.length; lane++)
        basicLibraryItems(_probeState(lane: lane)),
    ];
    _laneItemsSignature = signature;
    _laneItemsCache = table;
    return table;
  }

  /// 探针状态：只为复用 [basicLibraryItems] / [basicSelectedItemIndex] 的映射规则，
  /// 让 controller 的选中落点与 HUD 绘制/命中共用**同一份**列表真值。
  BasicViewState _probeState({BasicSelection? selection, int? lane}) {
    return BasicViewState(
      phase: _phase,
      query: _query,
      selectedLane: lane ?? _selectedLane,
      songs: _visibleSongs(lane: lane),
      albums: _visibleAlbums(lane: lane),
      album: _album,
      directory: _directory,
      song: _song,
      selection: selection ?? _selection,
      localCollectionsAvailable: _localCollectionsAvailable,
      localUnresolvedLikedIds: _localUnresolvedLikedIds,
      localPlaylists: _localPlaylists,
    );
  }

  /// 选曲时构造的队列：专辑详情内用详情曲目顺序，其余用当前过滤后的曲库顺序。
  List<SirenSong> _queueFor(SirenSong song) {
    final BasicDirectory? directory = _directory;
    if (directory != null &&
        directory.songs.any((SirenSong item) => item.id == song.id)) {
      // Qt/src/MusicLibrary.cpp:975-984 directorySource()：目录内播放的队列就是目录曲目，
      // ids 用目录自己的顺序（sortField == 'none' 分支）。
      return directory.songs;
    }
    final SirenAlbum? album = _album;
    if (album != null && album.id == song.albumId && album.songs.isNotEmpty) {
      return album.songs;
    }
    final List<SirenSong> visible = _visibleSongs();
    if (visible.any((SirenSong item) => item.id == song.id)) {
      return visible;
    }
    return <SirenSong>[song];
  }

  // ---------------------------------------------------------------------------
  // 播放：engine 端口实现（fresh 详情 → native prepare/play → playbackStarted）
  // ---------------------------------------------------------------------------

  Future<void> _startPlayback(Map<String, Object?> track, int generation) async {
    _activeGeneration = generation;
    final LyricsController lyrics = await _ensureLyrics();
    if (_activeGeneration != generation) {
      // 等 LyricsController.create 期间已被新的 play 取代：旧的一份不许再写歌词状态。
      return;
    }
    lyrics.load(track);
    _lyricDoc = BasicLyricsDocument.empty;
    _publish();
    final String id = _text(track['id']);
    if (id.isEmpty) {
      _player.fail(sirenNoSourceMessage, generation: generation);
      return;
    }
    try {
      final SirenSongDetail detail = await _repository.songDetail(id);
      if (_activeGeneration != generation) {
        return;
      }
      _rememberDetail(detail);
      if (detail.sourceUrl.isEmpty) {
        _player.fail(sirenNoSourceMessage, generation: generation);
        return;
      }
      await _audio.prepare(detail.sourceUrl, generation: generation);
      await _audio.play(generation: generation);
      // 真正开始播放（前台 Activity）时才拉起前台媒体服务；返回值只表示平台
      // 接受请求，通知是否可见取决于 POST_NOTIFICATIONS，失败不影响播放。
      unawaited(_mediaSession?.ensureStarted() ?? Future<bool>.value(false));
      _player.playbackStarted(generation: generation);
      unawaited(_loadLyrics(track, LyricsController.trackKey(track), detail.lyricUrl));
    } on Object catch (error) {
      _player.fail(_messageOf(error), generation: generation);
    }
  }

  void _rememberDetail(SirenSongDetail detail) {
    final SirenSong? cached = _songById[detail.id];
    final SirenSong seed = cached ??
        (_song != null && _song!.id == detail.id
            ? _song!
            : SirenSong(
                id: detail.id,
                title: detail.title.isEmpty ? sirenUnknownTitle : detail.title,
                artist: '',
                album: '',
                albumId: '',
                cover: '',
                sourceUrl: '',
                lyricUrl: '',
                durationMs: 0,
              ));
    final SirenSong updated = seed.copyWith(
      title: detail.title.isEmpty ? null : detail.title,
      sourceUrl: detail.sourceUrl,
      lyricUrl: detail.lyricUrl,
    );
    _songById[detail.id] = updated;
    if (_song?.id == detail.id) {
      _song = updated;
    }
  }

  Future<void> _loadLyrics(
    Map<String, Object?> track,
    String trackKey,
    String lyricUrl,
  ) async {
    final LyricsController lyrics = await _ensureLyrics();
    if (LyricsController.trackKey(_player.current) != trackKey) {
      // 曲目已切换：旧歌词（含空态/错误）不得覆盖新曲目的歌词面板。
      return;
    }
    if (lyricUrl.isEmpty) {
      _applyEmptyLyrics(lyrics);
      return;
    }
    try {
      final String text = await _repository.lyricsText(lyricUrl);
      if (LyricsController.trackKey(_player.current) != trackKey) {
        return;
      }
      if (text.trim().isEmpty || text.length > sirenMaxLyricLength) {
        _applyEmptyLyrics(lyrics);
        return;
      }
      BasicLyricsDocument document = parseBasicLyrics(text);
      if (document.isEmpty) {
        _applyEmptyLyrics(lyrics);
        return;
      }
      if (document.lines.length > sirenMaxLyricLines) {
        // 超出 validLyricsDocument 的 5000 行上限：截断，不把非法文档塞进域控制器。
        document = BasicLyricsDocument(
          lines: document.lines.sublist(0, sirenMaxLyricLines),
          offsetMs: document.offsetMs,
          plainText: '',
          timed: true,
        );
      }
      _lyricDoc = document;
      lyrics.accept(document.toLyricsDocument(), track);
      lyrics.sync(_number(_player.state['position']));
      _publish();
    } on SirenException catch (error) {
      if (LyricsController.trackKey(_player.current) != trackKey || _disposed) {
        return;
      }
      // 真实错误上屏（例如 '塞壬唱片资源请求失败（HTTP 500）'），不吞成"无歌词"。
      _lyricDoc = BasicLyricsDocument.empty;
      lyrics.status = 'empty';
      lyrics.message = error.message;
      _publish();
    }
  }

  void _applyEmptyLyrics(LyricsController lyrics) {
    _lyricDoc = BasicLyricsDocument.empty;
    lyrics.status = 'empty';
    lyrics.message = sirenEmptyLyricsMessage;
    _publish();
  }

  Future<LyricsController> _ensureLyrics() {
    return _lyricsFuture ??= _createLyrics();
  }

  Future<LyricsController> _createLyrics() async {
    final LyricsController controller = await LyricsController.create(_MemoryLyricsPreferences());
    if (_disposed) {
      return controller;
    }
    controller.addListener(_onLyricsChanged);
    _lyrics = controller;
    return controller;
  }

  // ---------------------------------------------------------------------------
  // 轮询与状态发布
  // ---------------------------------------------------------------------------

  void _startTicker() {
    if (_ticker != null) {
      return;
    }
    _clock.start();
    _ticker = Timer.periodic(const Duration(milliseconds: 100), (Timer timer) {
      _pump(_clock.elapsedMicroseconds / 1000000.0);
    });
  }

  void _pump(double seconds) {
    if (_disposed) {
      return;
    }
    _player.tick(seconds);
    final LyricsController? lyrics = _lyrics;
    if (lyrics != null) {
      lyrics.tick(seconds, positionMs: _number(_player.state['position']));
    }
  }

  void _onPlayerChanged() {
    _publish();
  }

  void _onLyricsChanged() => _publish();

  void _onAudioStateChanged(BasicAudioState state) => _publish();

  /// 播放身份（MusicPlayer 的 current 投影）；与选中 [_song] 严格分开。
  ///
  /// 旧实现 _syncSongFromPlayer 用播放身份**覆盖**选中，导致“浏览时被播放器回退”
  /// 和“没播也在假装播放”。Qt 的 archive 选中（MusicLibrary.current）与播放
  /// （MusicPlayer::current）本来就是两个值，播放器换曲不改选中。
  SirenSong? _playingTrackOf() {
    final Map<String, Object?> current = _player.current;
    final String id = _text(current['id']);
    if (id.isEmpty) {
      return null;
    }
    return _songById[id] ?? _songFromTrack(current);
  }

  void _publish() {
    if (_disposed) {
      return;
    }
    final Map<String, Object?> playerState = _player.state;
    final LyricsController? lyrics = _lyrics;
    _state = BasicViewState(
      phase: _phase,
      loading: _loading,
      error: _error,
      status: _status,
      query: _query,
      songs: _visibleSongs(),
      albums: _visibleAlbums(),
      album: _album,
      directory: _directory,
      song: _song,
      selection: _selection,
      playingTrack: _playingTrackOf(),
      listPosition: _listPosition,
      selectedLane: _selectedLane,
      laneItems: _laneItemTable(),
      laneOffsets: List<int>.unmodifiable(_laneOffsets),
      playing: playerState['playing'] == true,
      buffering: _audio.state.buffering,
      positionMs: _number(playerState['position']),
      durationMs: _number(playerState['duration']),
      playbackError: _player.failed ? _player.status : '',
      lyrics: _lyricDoc.lines,
      lyricIndex: lyrics?.index ?? -1,
      dark: _dark,
      queue: <SirenSong>[
        for (final Map<String, Object?> track in _player.queue.items) _songFromTrack(track),
      ],
      queueIndex: _player.queue.index,
      lyricStatus: lyrics?.status ?? 'idle',
      lyricMessage: lyrics?.message ?? '',
      playerStatus: _player.status,
      catalogLoaded: _catalogLoaded,
      localCollectionsAvailable: _localCollectionsAvailable,
      localUnresolvedLikedIds: _localUnresolvedLikedIds,
      localPlaylists: _localPlaylists,
    );
    notifyListeners();
    _syncMediaSession();
  }

  SirenSong _songFromTrack(Map<String, Object?> track) {
    final String id = _text(track['id']);
    final SirenSong? cached = _songById[id];
    if (cached != null) {
      return cached;
    }
    return SirenSong(
      id: id,
      title: _text(track['title']).isEmpty ? sirenUnknownTitle : _text(track['title']),
      artist: _text(track['artist']),
      album: _text(track['album']),
      albumId: _text(track['albumID']),
      cover: _text(track['cover']),
      // 显示用：播放直链一律由 _startPlayback fresh 读取，这里的值不参与播放。
      sourceUrl: _text(track['sourceUrl']),
      lyricUrl: '',
      durationMs: _number(track['duration']),
    );
  }

  /// MediaHostPort 的 mediaState：把 BasicAudioState 组装成 Qt 的键集
  /// （Qt/src/AudioPlayer.cpp:430-443），旧代读数整份丢弃。
  Map<String, Object?> _mediaState() {
    final BasicAudioState audio = _audio.state;
    if (audio.generation != 0 && audio.generation != _activeGeneration) {
      return const <String, Object?>{};
    }
    final double duration = audio.durationMs;
    return <String, Object?>{
      'playing': audio.playing,
      'position': audio.positionMs,
      'duration': duration,
      'seekable': duration > 0,
      'ended': _endedSerialFor(audio),
      'error': audio.error,
      // 基础版不做自动恢复（Qt 的 recoverable 分支会触发 _recoverPlayback 重播）；
      // 失败直接交给 MusicPlayer.fail 上屏，避免无声重试掩盖真实错误。
      'recoverable': false,
      'requested': audio.playing || audio.buffering,
      'buffering': audio.buffering,
    };
  }

  int _endedSerialFor(BasicAudioState audio) {
    if (audio.completed && !_completedSeen) {
      _endedSerial += 1;
    }
    _completedSeen = audio.completed;
    return _endedSerial;
  }

  String _messageOf(Object error) {
    if (error is SirenException) {
      return error.message;
    }
    return error.toString();
  }
}

/// MusicPlayer 的媒体宿主端口：命令转发给 lane B，状态读 lane B 的真实快照。
class _BasicMediaHost implements MediaHostPort {
  _BasicMediaHost(this._owner);

  final BasicController _owner;

  @override
  void mediaControl(String action, [double value = 0]) {
    final int generation = _owner._activeGeneration;
    switch (action) {
      case 'stop':
        unawaited(_owner._audio.stop());
        break;
      case 'pause':
        unawaited(_owner._audio.pause(generation: generation));
        break;
      case 'resume':
        unawaited(_owner._audio.play(generation: generation));
        break;
      case 'seek':
        unawaited(_owner._audio.seekTo(value, generation: generation));
        break;
      default:
        // 'volume' / 'metadata' 等不在基础版范围（音量由系统媒体控制）。
        break;
    }
  }

  @override
  Map<String, Object?> mediaState() => _owner._mediaState();

  @override
  void mediaMetadata(String title, String artist, String album, String cover) {
    // 通知栏/MediaSession 的上报归 lane B（platform_playback.dart 文件头已约定）；
    // 这里不做第二次上报，避免一条暂停写两次。
  }
}

/// PlaybackEnginePort：MusicPlayer 的 prepare 入口，委托给 controller 的 fresh 解析。
class _BasicPlaybackEngine implements PlaybackEnginePort {
  _BasicPlaybackEngine(this._owner);

  final BasicController _owner;

  @override
  void prepare(Map<String, Object?> track, int generation, {bool reload = false}) {
    unawaited(_owner._startPlayback(track, generation));
  }
}

/// 内存偏好实现（播放侧只用 'play-history'，Qt/src/MusicPlayer.cpp:188）。
class _MemoryPreferences implements PreferencePort {
  final Map<String, String> _values = <String, String>{};

  @override
  String read(String key) => _values[key] ?? '';

  @override
  void write(String key, String value) {
    _values[key] = value;
  }
}

/// 内存歌词偏好实现（只存 lyrics-global-offset-ms）。
class _MemoryLyricsPreferences implements LyricsPreferencePort {
  final Map<String, String> _values = <String, String>{};

  @override
  Future<String?> read(String key) async => _values[key];

  @override
  Future<void> write(String key, String value) async {
    _values[key] = value;
  }
}

String _text(Object? value) => value is String ? value : '';

double _number(Object? value) {
  if (value is num) {
    final double parsed = value.toDouble();
    return parsed.isFinite ? parsed : 0;
  }
  return 0;
}
