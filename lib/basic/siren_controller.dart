///  Siren 基本版的唯一业务 authority（导航 / 播放队列 / 歌词跟随）。
///
/// 分工（冻结契约 v1）：
///  - 本文件是**唯一**持有播放队列与当前曲的地方；UI 只读 [state]、只调这里的方法。
///  - 播放进度**只**来自 BasicAudioPort（android.media.MediaPlayer 的真实读数）：
///    经由 MusicPlayer.state 的 position/duration 进入 [state]；本文件从不 position += dt。
///  - 播放传输状态机复用 lib/domain/player/music_player.dart（MusicPlayer::tick 的移植），
///    这里只提供三个端口实现：MediaHostPort / PreferencePort / PlaybackEnginePort。
///  - 歌词复用 lib/domain/lyrics/lyrics_controller.dart 的 index 语义（upper_bound + offset），
///    位置同样只吃 native 读数。
///  - seekToFraction 只有两步：把比例命令下发 native（MusicPlayer.seek → mediaControl('seek')），
///    再用「native 已报的真实时长 × 比例」调一次 lyrics.sync 立即重算活动行；
///    绝不在本地先把 position 改成目标值，进度只认 native 回报（ 协调者 seq5 裁决 3b）。
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
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../domain/lyrics/lyrics_controller.dart';
import '../domain/models/provider_id.dart';
import '../domain/player/music_player.dart';
import '../domain/collection/local_collection_store.dart';
import '../domain/search/catalog_search.dart';
import '../domain/search/remote_search.dart';
import '../provider/plugin_gateway.dart' show ProviderRequestError;
import '../provider/provider_gateway.dart';
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
const String sirenProviderName = '塞壬唱片';
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

/// 「全部歌曲」目录的描述（Qt/src/MusicSiren.cpp:218 的模板：`<平台名>全部歌曲`）。
const String sirenAllSongsDescription = '塞壬唱片全部歌曲';

/// 「全部歌曲」标题后缀：描述串 = 平台名 + 这个后缀（插件/本地平台同样成立）。
const String sirenAllSongsTitleSuffix = '全部歌曲';

/// 打开目录/详情后的状态文案前缀（Qt/src/MusicSiren.cpp:242、MusicDirectory.cpp:445）。
const String sirenOpenedPrefix = '已打开：';

/// 打开一张没有曲目的本机歌单时的状态串（Qt `LocalCollections` 空歌单进列后
/// 目录 songs 为空，`status` 由 `MusicDirectory` 给「暂无曲目」；这里用同一句
/// 可见文案，不编造“已打开”）。
const String sirenEmptyPlaylistStatus = '该歌单暂无曲目';

/// 返回上一级的状态文案前缀（Qt/src/MusicDirectory.cpp:447）。
const String sirenReturnedPrefix = '已返回：';

/// provider 的显示名（Qt/src/MusicApi.cpp:16-17 的 providerName()：siren → '塞壬唱片'）。
const String sirenProviderLabel = '塞壬唱片';

/// Siren 基本版的单一 authority。
///
/// 构造注入 [BasicAudioPort]；[repository] 可注入（测试/替换 baseUri），
/// [dark] 只影响 [state].dark（基础版不做主题切换）。
///
/// 出厂默认**亮色**（用户 2026-11-19 指定；偏好里显式写了 dark 才会变暗）。
class BasicController extends ChangeNotifier
    implements BasicMediaSessionCommands {
  BasicController({
    required this._audio,
    SirenRepository? repository,
    bool dark = false,
    this._collections,
    this._collectionStore,
    MediaSessionPort? mediaSessionPort,
    BasicArtCache? artCache,
    PreferencePort? preferences,
  }) : _preferencesPort = preferences,
       _repository = repository ?? SirenRepository(),
       _ownsRepository = repository == null,
       _dark = dark {
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

  /// 封面落盘缓存（HUD 的封面像素也是从这份缓存读，见 BasicCoverImages）。
  /// 没有媒体端口也没有注入时为 null —— 那时界面画空槽，不编假图。
  BasicArtCache? get artCache => _artCache;

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

  /// 收藏的**写入口**（Qt `LocalCollections` 的写入面：toggleLike / like / unlike）。
  ///
  /// 与 [_collections] 分开：那是只读收窄端口（[BasicLocalCollections] 只有两个查询
  /// 方法，模型层不持有写能力），这里是真正的持久化实现，由宿主注入。null = 没有
  /// 本地存储（测试/桌面预览），此时喜欢开关回一句可见提示而不假装成功。
  final LocalCollectionStore? _collectionStore;

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

  /// 未播放曲目的歌词预览（用户 2026-11-24 要求「歌词和评论无需播放就能看」）。
  ///
  /// 与 [_lyricDoc] 分开存放是刻意的：那份是**播放曲目**的歌词，带进度高亮；
  /// 预览没有播放就没有进度，只把文本摆出来。开播时预览会被清掉，否则会出现
  /// 「标题是 A、歌词是 B」的身份串台。
  BasicLyricsDocument _previewLyricDoc = BasicLyricsDocument.empty;
  String _previewLyricId = '';
  String _previewLyricStatus = 'idle';
  String _previewLyricMessage = '';
  int _previewLyricGeneration = 0;

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

  /// 检索分类（Qt `MusicLibrary::searchKind`，取值见 [catalogSearchKinds]）。
  ///
  /// Qt 一次只搜一类（MusicSiren.cpp:140-176 的四个 case），「搜索结果」列
  /// （lane 0）只放该类的命中项；分类由 `music:kind:<i>` 切换（NativeHudMusic.cpp:218）。
  String _searchKind = catalogSearchKinds.first;

  /// 分组键（Qt `MusicLibrary::groupBy`：`none` / `artist` / `album`）。
  ///
  /// 只对「搜索结果」列里首条是曲目的情况生效（NativeHudSearch.cpp:85-88 的门控），
  /// 由 `music:group:<i>` 切换、`music:group-back` 复位。
  String _searchGroup = 'none';

  /// 已展开分组的标题（Qt `MusicLibrary::groupView` 的键）；空串 = 未展开。
  String _searchGroupKey = '';

  /// [searchOutcome] 的签名缓存（见该方法的失效规则）。
  String _searchOutcomeSignature = '';

  /// 远端（插件平台）检索网关；null = 当前平台用本地塞壬索引。
  ///
  /// 切到插件平台（`netease`/`qq`/…）后资料库仍是塞壬曲库，检索是唯一真正
  /// 走插件数据面的入口（Qt 里 `MusicLibrary::search` 直接调 `api.call("search")`）。
  ProviderGateway? _remoteSearch;

  /// 当前详情曲目的百科正文（Qt `NativeHudDetail.cpp:19-28` 的 `body()`：
  /// song + overview 页优先显示 `item["wiki"]`，空则给「暂无歌曲百科」）。
  /// 插件平台在打开详情时拉一次 `/native/<platform>/wiki`；塞壬平台没有百科。
  String _songWiki = '';
  bool _songWikiLoading = false;
  int _songWikiGeneration = 0;

  String get songWiki => _songWiki;
  bool get songWikiLoading => _songWikiLoading;

  /// 当前远端检索结果；null = 还没有结果（或本地模式）。
  RemoteSearchResult? _remoteSearchResult;

  /// 远端检索代际：切词/切分类/切平台时自增，用来丢弃过期响应。
  int _remoteSearchSeq = 0;

  /// 远端检索所属平台 id（切平台要清空旧结果）。
  String _remoteProviderId = '';
  String _remoteProviderName = '';

  /// 远端曲目 id → 插件原始行。
  ///
  /// `SirenSong` 只留得下 title/artist/album 这几个扁平字段，而
  /// 「↗ 歌手作品」（Qt `MusicDirectory.cpp:242-272`）要的是原始行里的
  /// `artists[{id,name}]`，所以把最近一次拿到的原始行按 id 存一份。
  final Map<String, Map<String, Object?>> _remoteRows =
      <String, Map<String, Object?>>{};

  /// 歌手页的标签：`songs`（曲目）/ `albums`（发行专辑），Qt `MusicDirectory::artistTab`。
  String _artistTab = 'songs';

  /// 歌手页「发行专辑」这一栏的行（Qt `MusicDirectory::albums`）。
  List<SirenAlbum> _artistAlbums = const <SirenAlbum>[];

  /// 当前平台的列名（插件平台来自 manifest 的 `library.columns`，否则塞壬五列）。
  List<String> _laneColumns = basicSirenColumns;

  /// 供 HUD/宿主读的列名（Qt `registry.columns(provider)`）。
  List<String> get laneColumns => _laneColumns;

  /// 列名（越界回空串）。
  String _laneName(int lane) =>
      lane >= 0 && lane < _laneColumns.length ? _laneColumns[lane] : '';

  /// 远端平台的默认音质 id（descriptor 的 `quality.default`；空 = 让插件用默认）。
  String _remoteQuality = '';
  SearchOutcome? _searchOutcomeCache;
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
  final List<double> _lanePositions = List<double>.filled(
    basicSirenColumns.length,
    0,
  );
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
    _status = _catalogLoadingStatus;
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
    if (_remoteSearch != null) {
      // 插件平台：检索由插件回答，不依赖本地塞壬曲库是否装载。
      _status = value.trim().isEmpty ? '请输入 1\u2013100 字关键词' : '正在检索…';
      _publish();
      if (value.trim().isNotEmpty) {
        unawaited(_runRemoteSearch());
      }
      return;
    }
    if (!_catalogLoaded) {
      if (!_loading) {
        _status = _libraryUnloadedStatus;
      }
      _publish();
      return;
    }
    // 计数与状态串走分类检索索引（Qt `searchSirenLocal` 的 status 原文）：
    // 空关键词是 MusicLibrary::search 的早退（`请输入 1–<maximum> 字关键词`，宽 100），
    // 非空时 total/status 由 CatalogSearchIndex 给出（没有匹配的音乐 / 没有匹配的
    // 本地歌单 / 找到 N 条结果，见 catalog_search.dart 的 _outcome）。
    final int count = value.trim().isEmpty ? 0 : searchOutcome().total;
    if (value.trim().isEmpty) {
      _status = '请输入 1\u2013100 字关键词';
    } else {
      _status = searchOutcome().status;
    }
    if (count > 0) {
      // Qt 的 showSource(0) 会 observe 该列的第一格（只选中，不播放）。
      final String status = _status;
      _selectRow(basicLibraryItems(_probeState()), 0);
      _status = status;
    }
    _publish();
  }

  /// 本机是否已接上收藏存储（`LocalCollectionStore`）。
  bool get collectionsWritable => _collectionStore != null;

  /// 「喜欢的歌曲」列的曲目（`_refreshLocalCollections` 解析后的结果）。
  ///
  /// 只读视图：`saved` 页要画喜欢列时宿主直接取它，不必先把 `selectedLane` 切到 1
  /// （切列会连带改列表滚动位置与音轨选择，Qt 里 saved 页的列表是独立的）。
  List<SirenSong> get likedSongs => _likedSongs;

  /// 本机自建歌单（`LocalCollections` 的只读视图）。
  List<BasicLocalPlaylist> get localPlaylists => _localPlaylists;

  /// 播放历史（Qt `MobileMusic::history`，上限 200、最近在前）。
  ///
  /// Qt 的「播放历史」页由 `discover:tab:history` 承载，但数据本体就是播放器
  /// 里那份 `play-history`（`MusicPlayer.cpp:188-198` 回填、`:667-675` 落盘），
  /// 所以这里直接读播放器，不另建缓存。
  List<SirenSong> get playHistory => <SirenSong>[
    for (final Map<String, Object?> track in _player.history)
      _songFromTrack(track),
  ];

  /// [songId] 是否在「喜欢的歌曲」里（空 id 恒 false，与 Qt `isLiked` 同）。
  bool isLiked(String songId) {
    // 插件平台（有服务端账号）优先读服务端集合：Qt `NativeHud.cpp:472` 的
    // `selectedLiked` 就是 `MusicLibrary` 里那份 `likedIDs`，本地集合只是塞壬的替身。
    if (_remoteSearch != null && _serverLikedIds.isNotEmpty) {
      return _serverLikedIds.contains(songId);
    }
    return _collectionStore?.isLiked(songId) ??
        (_collections?.likedIds().contains(songId) ?? false);
  }

  /// 切换一首歌的喜欢状态并刷新收藏列，返回结果文案（Qt `music:like` 的 status）。
  ///
  /// Qt 的等价点（MusicMutation.cpp:337）：`enabled = !liked` →
  /// `mutate("/like", {id, like: enabled})`，成功按响应 `state` 覆盖本地集合。
  /// 塞壬是本地集合（LocalCollections.cpp），所以这里直接 toggle 并落盘，
  /// 成功后 [_refreshLocalCollections] 把 liked 列表解析成曲目行并重建列缓存。
  Future<String> toggleLiked(String songId) async {
    if (songId.isEmpty) {
      return '无法写入本地收藏';
    }
    // 插件平台：喜欢状态在服务端（Qt `MusicMutation.cpp:337` 的 `mutate("/like")`）。
    final ProviderGateway? remote = _remoteSearch;
    if (remote != null) {
      final bool liked = !isLiked(songId);
      try {
        final bool nowLiked = await remote.setTrackLiked(
          trackId: songId,
          liked: liked,
        );
        if (_disposed) {
          return '';
        }
        if (nowLiked) {
          _serverLikedIds.add(songId);
        } else {
          _serverLikedIds.remove(songId);
        }
        _publish();
        return nowLiked ? '已加入喜欢的歌曲' : '已从喜欢的歌曲移除';
      } on Object catch (error) {
        return remoteErrorMessage(error);
      }
    }
    final LocalCollectionStore? store = _collectionStore;
    if (store == null) {
      return '本地收藏尚未接入';
    }
    await store.toggleLike(songId);
    _refreshLocalCollections();
    // 收藏列的内容签名变了（_collectionsDigest 参与 _laneItemTable 的签名），
    // 但 categories 的检索结果也依赖它，所以一并失效。
    _searchOutcomeCache = null;
    _publish();
    return store.status;
  }

  /// 切换「正在播放那首」的喜欢状态（Qt `music:like-current`）。
  Future<String> toggleLikeCurrent() {
    final Map<String, Object?> current = _player.current;
    return toggleLiked(current == null ? '' : _text(current['id']));
  }

  /// 把一首歌加进本机歌单（Qt `music:playlist-pick` 的 siren 分支，
  /// `NativeHudMusic.cpp:483-520`：先查重、再写、反馈落在按钮/状态行）。
  /// 返回状态文案：本地平台没有「已在当前歌单」那种目录上下文，查重只按歌单内容。
  Future<String> addToPlaylist(String playlistId, String songId) async {
    final ProviderGateway? gateway = _remoteSearch;
    if (gateway != null) {
      if (playlistId.isEmpty || songId.isEmpty) {
        return '无法写入歌单';
      }
      try {
        // 插件 `/playlist/tracks` 参数是 `{pid, tracks, op}`，tracks 用逗号分隔。
        await gateway.mutate('/playlist/tracks', <String, Object?>{
          'pid': playlistId,
          'tracks': songId,
          'op': 'add',
        });
        await refreshServerPlaylists();
        return '✓ 已加入歌单';
      } on Object catch (error) {
        return remoteErrorMessage(error);
      }
    }
    final LocalCollectionStore? store = _collectionStore;
    if (store == null) {
      return '本地收藏尚未接入';
    }
    if (playlistId.isEmpty || songId.isEmpty) {
      return '无法写入本地收藏';
    }
    if (store.playlistTrackIds(playlistId).contains(songId)) {
      return '✓ 已在当前歌单';
    }
    await store.addTrack(playlistId, songId);
    _refreshLocalCollections();
    _searchOutcomeCache = null;
    _publish();
    return store.status;
  }

  /// 当前选中曲目 + 平台自建歌单列表（`music:add-to-playlist` 打开选择器时要的数据）。
  String get selectedSongId => _song?.id ?? '';

  /// 创建本机歌单并刷新收藏列（Qt `music:create-playlist` 的 siren 分支，
  /// `MusicMutation.cpp:421-455`：校验名称 → 写文档 → 状态文案）。返回状态文案。
  Future<String> createPlaylist(String title) async {
    final ProviderGateway? gateway = _remoteSearch;
    if (gateway != null) {
      // 插件平台：Qt 走 `mutate("/playlist/create", {name})`（`MusicDirectory.cpp` 的歌单
      // 写操作），成功后刷新服务端歌单表。
      try {
        await gateway.mutate('/playlist/create', <String, Object?>{
          'name': title,
        });
        await refreshServerPlaylists();
        return '已创建歌单：$title';
      } on Object catch (error) {
        return remoteErrorMessage(error);
      }
    }
    final LocalCollectionStore? store = _collectionStore;
    if (store == null) {
      return '本地收藏尚未接入';
    }
    await store.createPlaylist(title);
    _refreshLocalCollections();
    _publish();
    return store.status;
  }

  /// 重命名本机歌单（Qt `music:rename-playlist`），返回状态文案。
  Future<String> renamePlaylist(String id, String title) async {
    final ProviderGateway? gateway = _remoteSearch;
    if (gateway != null) {
      try {
        await gateway.mutate('/playlist/name/update', <String, Object?>{
          'id': id,
          'name': title,
        });
        await refreshServerPlaylists();
        return '已重命名歌单：$title';
      } on Object catch (error) {
        return remoteErrorMessage(error);
      }
    }
    final LocalCollectionStore? store = _collectionStore;
    if (store == null) {
      return '本地收藏尚未接入';
    }
    await store.renamePlaylist(id, title);
    _refreshLocalCollections();
    _publish();
    return store.status;
  }

  /// 删除本机歌单（Qt `music:delete-playlist`），返回状态文案。
  Future<String> deletePlaylist(String id) async {
    final ProviderGateway? gateway = _remoteSearch;
    if (gateway != null) {
      try {
        await gateway.mutate('/playlist/delete', <String, Object?>{'id': id});
        await refreshServerPlaylists();
        return '已删除歌单';
      } on Object catch (error) {
        return remoteErrorMessage(error);
      }
    }
    final LocalCollectionStore? store = _collectionStore;
    if (store == null) {
      return '本地收藏尚未接入';
    }
    await store.deletePlaylist(id);
    _refreshLocalCollections();
    _publish();
    return store.status;
  }

  /// 切换检索分类（Qt `NativeHudMusic.cpp:218-236` 的 `kind` 分支）。
  ///
  /// Qt 的语义是：`text = query.isEmpty ? keyword : query`，
  /// `text.isEmpty ? 只改 searchKind : search(text, kind)`——也就是**有词就立即重搜**
  /// （重搜会把结果列 lane 0 的滚动窗口重置并重新选中第一行）；空词只换分类。
  /// `music:kind:<i>` 的 i 是 [catalogSearchKinds] 的下标（song/album/playlist/artist）。
  /// 返回是否真的切换了分类（越界或同值返回 false，宿主管文案）。
  bool setSearchKind(String kind) {
    if (_disposed) {
      return false;
    }
    if (!catalogSearchKinds.contains(kind)) {
      return false;
    }
    if (_searchKind == kind) {
      return false;
    }
    _searchKind = kind;
    _searchGroup = 'none';
    _searchGroupKey = '';
    if (_query.trim().isNotEmpty) {
      // 立即重搜：与 setQuery 的副作用同源（切 lane 0、清窗口、重新选中首行）。
      unawaited(setQuery(_query));
    } else {
      _publish();
    }
    return true;
  }

  /// 切换分组键（Qt `NativeHudMusic.cpp:238-250` 的 `group` 分支：只对曲目分类有效）。
  bool setSearchGroup(String group) {
    if (_disposed || _searchKind != catalogSearchKinds.first) {
      return false;
    }
    const List<String> allowed = <String>['none', 'artist', 'album'];
    if (!allowed.contains(group) || _searchGroup == group) {
      return false;
    }
    _searchGroup = group;
    _searchGroupKey = '';
    _publish();
    return true;
  }

  /// 展开某个分组（Qt `music:expand:<percentEncoded title>` → `setGroupView(title, indices, lane)`）。
  ///
  /// [value] 是分组标题原文（动作串里已解码）；空串等价于 [clearSearchGroup]。
  bool expandSearchGroup(String title) {
    if (_disposed || _searchKind != catalogSearchKinds.first || title.isEmpty) {
      return false;
    }
    _searchGroupKey = title;
    _publish();
    return true;
  }

  /// `music:group-back`：Qt 清掉分组视图回到原序列表。
  void clearSearchGroup() {
    if (_disposed) {
      return;
    }
    _searchGroupKey = '';
    _publish();
  }

  /// 当前检索分类（`song` / `album` / `playlist` / `artist`）。
  String get searchKind => _searchKind;

  /// 当前分组键（`none` / `artist` / `album`）。
  String get searchGroup => _searchGroup;

  /// 已展开分组的标题（空串 = 未展开）。
  String get searchGroupKey => _searchGroupKey;

  /// 分类检索的完整结果（不分页；宿主按可视行裁剪）。
  ///
  /// 返回 [CatalogSearchIndex] 的口径：`{items,total,hasMore,status,kind,query,start}`，
  /// `items` 里每项是 Qt `MusicData::item` 形状的 Map（kind/id/title/artist/album/cover…）。
  /// 分类为 `playlist` 时列表来自本机歌单（`_localPlaylists`）。
  ///
  /// 结果按「曲库代际 / 检索词 / 分类 / 收藏摘要」缓存：`_publish()` 每 100ms
  /// 随播放 tick 跑一次，整库 936 首的分类检索（且歌手分类还要归并）不能每帧
  /// 重算——那会把播放中的帧率拖垮。签名里不含分组键：分组只是对同一份结果的
  /// 视图裁剪，不需要重建索引。
  /// 是否走远端（插件）检索。
  bool get remoteSearchActive => _remoteSearch != null;

  /// 当前平台 id（远端检索结果按它隔离）。
  String get remoteProviderId => _remoteProviderId;

  /// 当前平台的显示名（Qt/src/MusicApi.cpp:10-24 `providerName()` 的同一张表）。
  ///
  /// 状态串/目录文案里的平台名一律取这里，不许再写死「塞壬唱片」：
  ///  - 还没绑定平台（`_remoteProviderId` 为空）→ 内置塞壬；
  ///  - `local` → 「本地音乐」（Qt 同名字面）；
  ///  - 插件平台优先用宿主传入的 manifest 显示名（[attachRemoteSearch] 的
  ///    `providerName`），没有就按 provider id 映射（netease/qq/kugou/siren）。
  String get providerName {
    if (_remoteProviderId.isEmpty) {
      return sirenProviderName;
    }
    if (_remoteProviderId == ProviderId.local.wire) {
      return ProviderId.local.displayName;
    }
    if (_remoteProviderName.isNotEmpty) {
      return _remoteProviderName;
    }
    return ProviderId.parse(_remoteProviderId).displayName;
  }

  /// 绑定远端检索网关：宿主在平台装配/切换时调用，null = 回本地塞壬索引。
  ///
  /// 换平台时清空旧结果并让在途响应失效（`_remoteSearchSeq++`），否则会把
  /// 上一个平台的命中项画到新平台下。
  void attachRemoteSearch(
    ProviderGateway? gateway, {
    required String providerId,
    String quality = '',
    String providerName = '',
    List<String> columns = basicSirenColumns,
  }) {
    // 列名随平台走（Qt `registry.columns(provider)`）：插件平台的 manifest
    // `library.columns` 与塞壬五列不同名，标题/状态串都要跟着换。
    _laneColumns = columns.isEmpty ? basicSirenColumns : columns;
    if (identical(gateway, _remoteSearch) &&
        providerId == _remoteProviderId &&
        providerName == _remoteProviderName) {
      _publish();
      return;
    }
    _remoteSearch = gateway;
    _remoteProviderId = providerId;
    _remoteProviderName = providerName;
    _remoteQuality = quality;
    _remoteSearchResult = null;
    _refreshPlatformStatus();
    ++_remoteSearchSeq;
    if (gateway != null && _query.trim().isNotEmpty) {
      unawaited(_runRemoteSearch());
    }
    if (!_disposed) {
      _publish();
    }
  }

  /// 平台切换后把仍是「塞壬唱片」字样的自动状态串翻成新平台名。
  ///
  /// 只改由曲库加载流程生成的那几条（插件/用户给的业务状态不动），否则切到
  /// 网易云后首帧还会闪一条「正在读取塞壬唱片曲库…」。
  void _refreshPlatformStatus() {
    if (_status == sirenCatalogLoadingStatus ||
        _status.startsWith('$sirenCatalogLoadingStatus（')) {
      final String suffix = _status.substring(sirenCatalogLoadingStatus.length);
      _status = '$_catalogLoadingStatus$suffix';
    } else if (_status.startsWith(sirenCatalogFailurePrefix)) {
      _status =
          _catalogFailurePrefix +
          _status.substring(sirenCatalogFailurePrefix.length);
    } else if (_status == sirenLibraryUnloadedStatus) {
      _status = _libraryUnloadedStatus;
    } else if (_status.startsWith(sirenCatalogLoadedPrefix) ||
        _status.startsWith('$sirenProviderName：')) {
      _status = _catalogLoadedStatus();
    }
  }

  /// 服务端喜欢的翻页游标：Qt `MusicLibrary::loadLikedIDs` 是
  /// `songs(slice(ids, likedCursor, 100))` 逐段解析（`likedCursor += page.rawCount`），
  /// 而不是一次性把 965 条全塞进 `songs`。这里只记游标，id 全量表已在
  /// [_serverLikedIds] 里，翻页只补曲目行。
  int get serverLikedCursor => _serverLikedCursor;
  int _serverLikedCursor = 0;

  /// 服务端喜欢的翻页页大小（Qt `slice(ids, handler, 100)`）。
  static const int serverLikedPageSize = 100;

  /// 是否还有更多服务端喜欢的曲目没解析（Qt `hasMore[1] = likedCursor < ids.size`）。
  bool get serverLikedHasMore =>
      _serverLikedCursor < _orderedServerLikedIds.length;

  /// 按 id 全量表顺序取 id 切片（`_serverLikedIds` 是 Set，顺序不可依赖）。
  List<String> _orderedServerLikedIds = const <String>[];

  /// 续页：把下一页的裸 id 解析成曲目行并追加到 [_serverLikedSongs]。
  ///
  /// Qt `MusicLibrary::loadLikedIDs(lane, token, user)`（`Qt/src/MusicLibrary.cpp:1000-1030`）
  /// 每页都会重新取 `likedIDs` 再 `songs(slice(...))`；这里首屏已经拿过全量 id，
  /// 续页直接从本地那份顺序表切片，少一次往返。
  Future<void> loadMoreServerLiked() async {
    final ProviderGateway? gateway = _remoteSearch;
    if (gateway == null || _disposed || !serverLikedHasMore) {
      return;
    }
    final int seq = ++_serverLikedSeq;
    try {
      await _loadServerLikedPage(gateway, seq);
      if (_disposed || seq != _serverLikedSeq) {
        return;
      }
      _publish();
    } on Object catch (error) {
      if (_disposed) {
        return;
      }
      _status = remoteErrorMessage(error);
      _publish();
    }
  }

  /// 拉一页并追加（调用方负责代际与 `_publish()`）。
  Future<void> _loadServerLikedPage(ProviderGateway gateway, int seq) async {
    final int start = _serverLikedCursor;
    final int end = math.min(
      start + serverLikedPageSize,
      _orderedServerLikedIds.length,
    );
    if (end <= start) {
      return;
    }
    final List<Map<String, Object?>> rows = await gateway.songsByIds(
      _orderedServerLikedIds.sublist(start, end),
    );
    if (_disposed || seq != _serverLikedSeq) {
      return;
    }
    _serverLikedSongs = <SirenSong>[
      ..._serverLikedSongs,
      for (final Map<String, Object?> row in rows) _songFromRemoteRow(row),
    ];
    _serverLikedCursor = end;
  }

  /// 远端「喜欢的歌曲」id 集合（插件平台走服务端 `likedIDs`，本地平台为空）。
  ///
  /// Qt 的等价点：`MusicLibrary.cpp:969` 拉 `likedIDs` 后填 `likedIDs` 集合，
  /// 详情页心形与 immerse 条的 `music:like-current` 都读它。
  Set<String> get serverLikedIds => _serverLikedIds;
  Set<String> _serverLikedIds = <String>{};

  /// 服务端「我的歌单」（插件平台的 `userPlaylists(uid)`，Qt `MusicLibrary.cpp:1030-1070`
  /// 把 `creatorID == uid` 的归属歌单放进 lists[2]）。
  List<BasicLocalPlaylist> get serverPlaylists => _serverPlaylists;
  List<BasicLocalPlaylist> _serverPlaylists = const <BasicLocalPlaylist>[];
  int _serverPlaylistSeq = 0;

  /// 打开服务端歌单（插件平台）：Qt 走 `MusicDirectory.cpp:88-150` 的 `detail`，
  /// 返回 `[item, songs, ids]`，Flutter 只取 songs 并把它建成一个目录。
  ///
  /// 塞壬/本地平台的歌单仍走本机集合（`_localPlaylists`），不进这条路径。
  ///
  /// `kind` 只有发现页的「新专辑」用得上：Qt `MusicDiscover::open` 对
  /// `kind != "song"` 一律 `enterDirectory(value)`（`MusicDiscover.cpp:112-126`），
  /// 专辑条目就是 `{kind:"album"}` 的目录，插件 `detail` 同样按 `kind` 分派。
  Future<String> enterRemotePlaylist(
    BasicLocalPlaylist playlist, {
    String kind = 'playlist',
    String cover = '',
  }) async {
    final ProviderGateway? gateway = _remoteSearch;
    if (gateway == null || _disposed) {
      return '当前来源不支持歌单';
    }
    final int generation = ++_detailGeneration;
    _status = '正在打开：${playlist.title}';
    _loading = true;
    _publish();
    try {
      final List<Map<String, Object?>> rows = await gateway.detailSongs(
        <String, Object?>{
          'kind': kind,
          'id': playlist.id,
          'title': playlist.title,
          'provider': _remoteProviderId,
          'key': '$_remoteProviderId:$kind:${playlist.id}',
        },
      );
      if (generation != _detailGeneration || _disposed) {
        return '';
      }
      final List<SirenSong> songs = <SirenSong>[
        for (final Map<String, Object?> row in rows) _songFromRemoteRow(row),
      ];
      for (final SirenSong song in songs) {
        _songById[song.id] = song;
      }
      _directory = BasicDirectory(
        provider: _remoteProviderId.isEmpty ? sirenProvider : _remoteProviderId,
        kind: kind,
        id: playlist.id,
        key: '$_remoteProviderId:$kind:${playlist.id}',
        title: playlist.title,
        artist: '',
        cover: songs.isEmpty ? cover : songs.first.cover,
        description: '${songs.length} 首',
        trackCount: songs.length,
        virtual: false,
        songs: songs,
        ids: <String>[for (final SirenSong song in songs) song.id],
        cursor: songs.length,
        index: 0,
        parent: _directory,
        parentLane: _selectedLane,
        parentSelection: _selection,
      );
      _album = null;
      _phase = BasicPhase.library;
      _query = '';
      _loading = false;
      _error = '';
      _status = songs.isEmpty ? '歌单暂无可播放曲目' : '已打开：${playlist.title}';
      _song = songs.isEmpty ? null : songs.first;
      _selection = songs.isEmpty
          ? null
          : BasicSelection(kind: 'song', id: songs.first.id);
      _listPosition = 0;
      _publish();
      return _status;
    } on Object catch (error) {
      if (generation != _detailGeneration || _disposed) {
        return '';
      }
      _loading = false;
      _status = remoteErrorMessage(error);
      _publish();
      return _status;
    }
  }

  /// 打开**本机自建歌单**：把它当成目录（`kind: 'playlist'`）进列，留在资料库。
  ///
  /// Qt 真值（`Qt/src/MusicLibrary.cpp:829-869` 的 `selectResult(index, lane, open=true)`）：
  /// 点歌单行时 `mode = "archive"`（因为 `kind != "song"`），随后
  /// `if (open && current["kind"] != "song") enterDirectory(current)`；目录内容由
  /// `MusicDirectory::enterDirectory` 的 `detail` 分支取回 `songs`（Qt/src/MusicDirectory.cpp:88-150）。
  ///
  /// 本机歌单的曲目 id 存在 [LocalCollectionStore] 里（`playlistTrackIds` 从新到旧），
  /// 曲目本体来自曲库/详情缓存（[resolveSongById]）；解析不到的 id 只计数、不编曲目
  /// （Qt 也是拿 id 再去请求 songs，拿不到就空目录）。插件平台的歌单不走这里，
  /// 见 [enterRemotePlaylist]。
  Future<String> enterLocalPlaylist(BasicLocalPlaylist playlist) async {
    if (_disposed) {
      return '';
    }
    final LocalCollectionStore? store = _collectionStore;
    if (store == null) {
      return '本地收藏尚未接入';
    }
    ++_detailGeneration;
    ++_songGeneration;
    final List<SirenSong> songs = <SirenSong>[
      for (final String id in store.playlistTrackIds(playlist.id))
        if (_resolveSongById(id) case final SirenSong song) song,
    ];
    for (final SirenSong song in songs) {
      _songById[song.id] = song;
    }
    _directory = BasicDirectory(
      provider: sirenProvider,
      kind: 'playlist',
      id: playlist.id,
      key: '$sirenProvider:playlist:${playlist.id}',
      title: playlist.title.isEmpty ? '未命名歌单' : playlist.title,
      artist: providerName,
      cover: songs.isEmpty ? '' : songs.first.cover,
      // Qt `LocalCollections.cpp:144` 的 description 原文；本机歌单没有别的副标题。
      description: '本地歌单 · 仅保存在本机',
      trackCount: songs.length,
      virtual: false,
      songs: songs,
      ids: <String>[for (final SirenSong song in songs) song.id],
      cursor: songs.length,
      index: 0,
      parent: _directory,
      parentLane: _selectedLane,
      parentSelection: _selection,
    );
    _album = null;
    _phase = BasicPhase.library;
    _query = '';
    _loading = false;
    _error = '';
    _status = songs.isEmpty ? sirenEmptyPlaylistStatus : '$sirenOpenedPrefix${_directory!.title}';
    _song = songs.isEmpty ? null : songs.first;
    _selection =
        songs.isEmpty ? null : BasicSelection(kind: 'song', id: songs.first.id);
    _listPosition = 0;
    _publish();
    return '';
  }

  /// 歌手页的标签（`songs` / `albums`）。
  String get artistTab => _artistTab;

  /// 歌手页「发行专辑」栏的行。
  List<SirenAlbum> get artistAlbums => _artistAlbums;

  /// 当前是否停在歌手页（`phase == detail` 且目录 kind 是 `artist`）。
  ///
  /// Qt 的歌手页是 detail 模式（`MusicDirectory::showDirectoryInfo()` 发
  /// `modeRequested("detail")`），但目录本身仍然留着，所以宿主用这个组合判断，
  /// 不要只看 `phase`。
  bool get artistPageActive {
    final BasicDirectory? directory = _directory;
    return _phase == BasicPhase.detail &&
        directory != null &&
        directory.kind == 'artist';
  }

  /// 歌手页标题（非歌手页为空串）。
  String get artistName => artistPageActive ? _directory!.title : '';

  /// 歌手页封面（非歌手页为空串）。
  String get artistCover => artistPageActive ? _directory!.cover : '';

  /// 歌手页曲目（非歌手页为空列表）。
  List<SirenSong> get artistSongs =>
      artistPageActive ? _directory!.songs : const <SirenSong>[];

  /// 切换歌手页标签：`songs` / `albums`（Qt `music:artist-tab:songs|albums`）。
  ///
  /// 只改视图，不重新请求、不动选中：Qt 的 artistTab 同样只是容器的取数开关。
  void setArtistTab(String tab) {
    if (_disposed || (tab != 'songs' && tab != 'albums') || _artistTab == tab) {
      return;
    }
    _artistTab = tab;
    _publish();
  }

  /// 「↗ 歌手作品」：进入该歌手的目录页（Qt `MusicDirectory::openSongArtist`）。
  ///
  /// Qt 真值（`Qt/src/MusicDirectory.cpp:242-272`）：
  ///  - 插件平台取 `current["artists"][index]` 的 `{id,name}`，id 必须匹配
  ///    `^[a-zA-Z0-9_-]{1,80}$`，否则**静默不打开**；
  ///  - 本地平台（这里把塞壬曲库当本地库）用 `{provider:"local",kind:"artist",
  ///    id,key:"local:artist:"+id,title:name}` 建目录；
  ///  - 目录内容由 `enterDirectory` 的 `detail` 返回 `[item, songs, ids]`，
  ///    状态串是「正在打开：<title>」→「已打开：<title>」。
  ///
  /// [artistIndex] 是歌曲行 `artists[]` 里的下标（动作 `music:artist:<i>` 的 i）；
  /// [artistId] 是调用方已经解析好的 id（插件行里没有 artists 时才需要）。
  Future<void> openArtistDirectory(
    String name, {
    int artistIndex = 0,
    String artistId = '',
  }) async {
    if (_disposed) {
      return;
    }
    final String artist = name.trim();
    if (artist.isEmpty) {
      _status = '歌手信息不完整，无法打开歌手页';
      _publish();
      return;
    }
    final ProviderGateway? gateway = _remoteSearch;
    final int generation = ++_detailGeneration;
    _status = '正在打开：$artist';
    _loading = true;
    _error = '';
    _publish();
    String provider = sirenProvider;
    String id = artistId.trim();
    String key = 'siren:artist:${id.isEmpty ? artist : id}';
    List<SirenSong> songs = const <SirenSong>[];
    List<SirenAlbum> albums = const <SirenAlbum>[];
    try {
      if (gateway != null) {
        provider = _remoteProviderId.isEmpty
            ? sirenProvider
            : _remoteProviderId;
        if (id.isEmpty) {
          id = _artistIdFromCurrentSong(artist, artistIndex);
        }
        if (id.isEmpty) {
          // 拿不到 artist id（例如详情页停在塞壬曲库的曲目上：`_remoteRows` 里
          // 没有它的原始行，插件也没给 `artists[]`）。这时不能像 Qt 那样静默
          // no-op：回退成「按歌手名在本地曲库里筛」，页面至少能给出该歌手的
          // 本地作品，而不是点了没反应。
          songs = <SirenSong>[
            for (final SirenSong song in _catalogSongs)
              if (_songMatchesArtist(song, artist)) song,
          ];
          albums = <SirenAlbum>[
            for (final SirenAlbum album in _catalogAlbums)
              if (_albumMatchesArtist(album, artist)) album,
          ];
          if (songs.isEmpty && albums.isEmpty) {
            _loading = false;
            _status = '歌手信息不完整，无法打开歌手页';
            _publish();
            return;
          }
          provider = sirenProvider;
          key = 'siren:artist:$artist';
        } else {
          key = '$provider:artist:$id';
          final List<Map<String, Object?>> rows = await gateway.detailSongs(
            <String, Object?>{
              'provider': provider,
              'kind': 'artist',
              'id': id,
              'key': key,
              'title': artist,
              'artist': artist,
            },
          );
          if (generation != _detailGeneration) {
            return;
          }
          songs = <SirenSong>[
            for (final Map<String, Object?> row in rows)
              _songFromRemoteRow(row),
          ];
        }
      } else {
        songs = <SirenSong>[
          for (final SirenSong song in _catalogSongs)
            if (_songMatchesArtist(song, artist)) song,
        ];
        albums = <SirenAlbum>[
          for (final SirenAlbum album in _catalogAlbums)
            if (_albumMatchesArtist(album, artist)) album,
        ];
      }
    } on Object catch (error) {
      if (generation != _detailGeneration || _disposed) {
        return;
      }
      _loading = false;
      _error = _messageOf(error);
      _status = sirenDetailFailurePrefix + _error;
      _publish();
      return;
    }
    if (generation != _detailGeneration || _disposed) {
      return;
    }
    for (final SirenSong song in songs) {
      _songById[song.id] = song;
    }
    if (albums.isEmpty) {
      albums = _albumsFromSongs(songs, artist);
    }
    final String cover = songs.isEmpty ? '' : songs.first.cover;
    _artistAlbums = List<SirenAlbum>.unmodifiable(albums);
    _artistTab = 'songs';
    _directory = BasicDirectory(
      provider: provider,
      kind: 'artist',
      // Qt 的目录 item id 就是歌手 id；本地/无 id 时退回 key，保持身份可比较。
      id: id.isEmpty ? key : id,
      key: key,
      title: artist,
      artist: artist,
      cover: cover,
      description: songs.isEmpty
          ? '暂无该歌手的曲目'
          : '${songs.length} 首曲目 · ${albums.length} 张专辑',
      trackCount: songs.length,
      virtual: false,
      songs: songs,
      ids: <String>[for (final SirenSong song in songs) song.id],
      cursor: songs.length,
      index: 0,
      parent: _directory,
      parentLane: _selectedLane,
      parentSelection: _selection,
    );
    _album = null;
    _phase = BasicPhase.detail;
    _query = '';
    _loading = false;
    _error = '';
    _status = songs.isEmpty && albums.isEmpty
        ? '没有找到该歌手的作品'
        : '$sirenOpenedPrefix$artist';
    _song = songs.isEmpty ? null : songs.first;
    _selection = songs.isEmpty
        ? null
        : BasicSelection(kind: 'song', id: songs.first.id);
    _listPosition = 0;
    _publish();
  }

  /// 打开歌手页里第 [index] 张专辑（Qt `music:artist-album:<rawIndex>`）。
  ///
  /// 塞壬/本地平台复用 [enterAlbumColumn]（曲库里的专辑详情）；插件平台走
  /// `detail` 的 `kind == "album"` 分支（`MusicDirectory::enterDirectory` 同义）。
  Future<void> openArtistAlbum(int index) async {
    if (_disposed) {
      return;
    }
    final List<SirenAlbum> albums = _artistAlbums;
    if (index < 0 || index >= albums.length) {
      _status = '该专辑已不在列表里';
      _publish();
      return;
    }
    final SirenAlbum album = albums[index];
    final ProviderGateway? gateway = _remoteSearch;
    if (gateway == null) {
      await enterAlbumColumn(album);
      return;
    }
    final int generation = ++_detailGeneration;
    _status = '正在打开：${album.name}';
    _loading = true;
    _error = '';
    _publish();
    try {
      final List<Map<String, Object?>> rows = await gateway.detailSongs(
        <String, Object?>{
          'provider': _remoteProviderId,
          'kind': 'album',
          'id': album.id,
          'key': '$_remoteProviderId:album:${album.id}',
          'title': album.name,
          'artist': album.artist,
        },
      );
      if (generation != _detailGeneration || _disposed) {
        return;
      }
      final List<SirenSong> songs = <SirenSong>[
        for (final Map<String, Object?> row in rows) _songFromRemoteRow(row),
      ];
      for (final SirenSong song in songs) {
        _songById[song.id] = song;
      }
      _directory = BasicDirectory(
        provider: _remoteProviderId.isEmpty ? sirenProvider : _remoteProviderId,
        kind: 'album',
        id: album.id,
        key: '$_remoteProviderId:album:${album.id}',
        title: album.name,
        artist: album.artist,
        cover: album.cover.isNotEmpty
            ? album.cover
            : (songs.isEmpty ? '' : songs.first.cover),
        description: album.artist,
        trackCount: songs.length,
        virtual: false,
        songs: songs,
        ids: <String>[for (final SirenSong song in songs) song.id],
        cursor: songs.length,
        index: 0,
        parent: _directory,
        parentLane: _selectedLane,
        parentSelection: _selection,
      );
      _album = null;
      _phase = BasicPhase.library;
      _query = '';
      _loading = false;
      _error = '';
      _status = songs.isEmpty ? '专辑暂无可播放曲目' : '$sirenOpenedPrefix${album.name}';
      _song = songs.isEmpty ? null : songs.first;
      _selection = songs.isEmpty
          ? null
          : BasicSelection(kind: 'song', id: songs.first.id);
      _listPosition = 0;
      _publish();
    } on Object catch (error) {
      if (generation != _detailGeneration || _disposed) {
        return;
      }
      _loading = false;
      _error = _messageOf(error);
      _status = sirenDetailFailurePrefix + _error;
      _publish();
    }
  }

  /// 从当前选中曲目的插件原始行里取第 [index] 个歌手的 id。
  String _artistIdFromCurrentSong(String name, int index) {
    final SirenSong? song = _song;
    if (song == null) {
      return '';
    }
    final Map<String, Object?>? row = _remoteRows[song.id];
    final Object? artists = row?['artists'];
    if (artists is! List) {
      return '';
    }
    final List<Map<String, Object?>> entries = <Map<String, Object?>>[
      for (final Object? entry in artists)
        if (entry is Map)
          entry.map(
            (Object? key, Object? value) =>
                MapEntry<String, Object?>('$key', value),
          ),
    ];
    if (index >= 0 && index < entries.length) {
      final String id = _text(entries[index]['id']);
      if (id.isNotEmpty) {
        return id;
      }
    }
    for (final Map<String, Object?> entry in entries) {
      if (_text(entry['name']) == name) {
        return _text(entry['id']);
      }
    }
    return '';
  }

  /// 曲目是否属于歌手 [artist]（`artist` 可能是 `A / B` 形式的多歌手串）。
  bool _songMatchesArtist(SirenSong song, String artist) {
    if (song.artist == artist) {
      return true;
    }
    for (final String part in song.artist.split(' / ')) {
      if (part.trim() == artist) {
        return true;
      }
    }
    return song.artist.contains(artist);
  }

  /// 专辑是否属于歌手 [artist]（同上）。
  bool _albumMatchesArtist(SirenAlbum album, String artist) {
    if (album.artist == artist) {
      return true;
    }
    for (final String part in album.artist.split(' / ')) {
      if (part.trim() == artist) {
        return true;
      }
    }
    return album.artist.contains(artist);
  }

  /// 从歌手曲目里按 album/albumID 去重出专辑行（插件 `artistAlbums` 未接入时的
  /// 诚实投影：只列这些曲目所属的专辑，不编造别处的发行）。
  List<SirenAlbum> _albumsFromSongs(List<SirenSong> songs, String artist) {
    final Map<String, SirenAlbum> byKey = <String, SirenAlbum>{};
    for (final SirenSong song in songs) {
      if (song.album.isEmpty) {
        continue;
      }
      final String id = song.albumId.isEmpty ? song.album : song.albumId;
      final SirenAlbum? existing = byKey[id];
      byKey[id] = SirenAlbum(
        id: id,
        name: song.album,
        artist: artist,
        cover: song.cover,
        songCount: (existing?.songCount ?? 0) + 1,
        songs: const <SirenSong>[],
      );
    }
    return <SirenAlbum>[for (final SirenAlbum album in byKey.values) album];
  }

  // ── 歌曲百科 / 专辑信息 ────────────────────────────────────────────────
  //
  // Qt 真值：`MusicLibrary.cpp:591-598` 在歌曲详情里补 `wiki`
  // （`api.call("wiki", {id})`，结果是一段纯文本）；专辑页走 `detail` 的 album 分支。
  // 塞壬平台没有百科接口，页面必须显示诚实状态串，不能编数据。

  String _wikiTrackId = '';
  String _wikiTitle = '';
  String _wikiArtist = '';
  String _wikiCover = '';
  String _wikiText = '';
  String _wikiStatus = '';
  bool _wikiLoading = false;

  /// 百科页是否已打开（`trackId` 非空）。
  bool get wikiActive => _wikiTrackId.isNotEmpty;
  String get wikiTrackId => _wikiTrackId;
  String get wikiTitle => _wikiTitle;
  String get wikiArtist => _wikiArtist;
  String get wikiCover => _wikiCover;
  String get wikiText => _wikiText;
  String get wikiStatus => _wikiStatus;
  bool get wikiLoading => _wikiLoading;

  /// 百科正文按行切开（插件给的是 `标签：值` 的纯文本，一段一行）。
  List<String> get wikiLines => <String>[
    for (final String line in _wikiText.split('\n'))
      if (line.trim().isNotEmpty) line.trim(),
  ];

  /// 打开「歌曲百科」页：有插件来源就问 `/native/<platform>/wiki`，
  /// 塞壬/本地平台直接给诚实状态串（Qt 里 wiki 为空时显示「暂无歌曲百科」）。
  Future<void> openSongWiki({
    String trackId = '',
    String title = '',
    String artist = '',
    String cover = '',
  }) async {
    if (_disposed) {
      return;
    }
    final SirenSong? song = _song;
    final String id = trackId.trim().isNotEmpty
        ? trackId.trim()
        : (song?.id ?? '');
    if (id.isEmpty) {
      _status = '没有选中的曲目';
      _publish();
      return;
    }
    _wikiTrackId = id;
    _wikiTitle = title.isNotEmpty ? title : (song?.title ?? '');
    _wikiArtist = artist.isNotEmpty ? artist : (song?.artist ?? '');
    _wikiCover = cover.isNotEmpty ? cover : (song?.cover ?? '');
    _wikiText = '';
    _wikiLoading = false;
    final ProviderGateway? gateway = _remoteSearch;
    if (gateway == null) {
      _wikiStatus = '$providerName不提供歌曲百科';
      _publish();
      return;
    }
    _wikiLoading = true;
    _wikiStatus = '正在读取歌曲百科…';
    _publish();
    try {
      final Map<String, Object?> value = await gateway.wiki(trackId: id);
      if (_disposed || _wikiTrackId != id) {
        return;
      }
      _wikiText = _text(value['text']);
      _wikiLoading = false;
      _wikiStatus = _wikiText.isEmpty ? '$providerName暂未收录这首歌的百科' : '';
      _publish();
    } on Object catch (error) {
      if (_disposed || _wikiTrackId != id) {
        return;
      }
      _wikiLoading = false;
      _wikiText = '';
      _wikiStatus = remoteErrorMessage(error);
      _publish();
    }
  }

  /// 关掉百科页（回到调用它的页面，不动播放/目录）。
  void closeSongWiki() {
    if (_disposed || _wikiTrackId.isEmpty) {
      return;
    }
    _wikiTrackId = '';
    _wikiText = '';
    _wikiStatus = '';
    _wikiLoading = false;
    _publish();
  }

  String _albumInfoId = '';
  String _albumInfoTitle = '';
  String _albumInfoArtist = '';
  String _albumInfoCover = '';
  String _albumInfoDate = '';
  String _albumInfoDescription = '';
  int _albumInfoTrackCount = 0;
  String _albumInfoStatus = '';
  bool _albumInfoLoading = false;
  List<SirenSong> _albumInfoSongs = const <SirenSong>[];

  /// 专辑信息页是否已打开（`albumId` 非空）。
  bool get albumInfoActive => _albumInfoId.isNotEmpty;
  String get albumInfoId => _albumInfoId;
  String get albumInfoTitle => _albumInfoTitle;
  String get albumInfoArtist => _albumInfoArtist;
  String get albumInfoCover => _albumInfoCover;
  String get albumInfoDate => _albumInfoDate;
  String get albumInfoDescription => _albumInfoDescription;
  int get albumInfoTrackCount => _albumInfoTrackCount;
  String get albumInfoStatus => _albumInfoStatus;
  bool get albumInfoLoading => _albumInfoLoading;
  List<SirenSong> get albumInfoSongs => _albumInfoSongs;

  /// 打开「专辑信息」页（封面 + 专辑名 + 艺人 + 发行信息 + 同专辑曲目）。
  ///
  /// 插件平台用 `albumInfo`（网关内部走 `detail` 的 album 分支）；塞壬平台没有
  /// 独立专辑信息接口，只填本地曲库确实有的字段，缺的留空并说明。
  Future<void> openAlbumInfo({
    String albumId = '',
    String title = '',
    String artist = '',
    String cover = '',
  }) async {
    if (_disposed) {
      return;
    }
    final String id = albumId.trim().isNotEmpty
        ? albumId.trim()
        : (_album?.id ?? _directory?.id ?? '');
    if (id.isEmpty) {
      _status = '没有选中的专辑';
      _publish();
      return;
    }
    _albumInfoId = id;
    _albumInfoTitle = title;
    _albumInfoArtist = artist;
    _albumInfoCover = cover;
    _albumInfoDate = '';
    _albumInfoDescription = '';
    _albumInfoTrackCount = 0;
    _albumInfoSongs = const <SirenSong>[];
    _albumInfoLoading = false;
    final ProviderGateway? gateway = _remoteSearch;
    if (gateway == null) {
      await _openLocalAlbumInfo(id);
      return;
    }
    _albumInfoLoading = true;
    _albumInfoStatus = '正在读取专辑信息…';
    _publish();
    try {
      final Map<String, Object?> value = await gateway.albumInfo(albumId: id);
      if (_disposed || _albumInfoId != id) {
        return;
      }
      final Map<String, Object?> album = value['album'] is Map
          ? (value['album'] as Map).map(
              (Object? key, Object? item) =>
                  MapEntry<String, Object?>('$key', item),
            )
          : const <String, Object?>{};
      final List<SirenSong> songs = value['songs'] is List
          ? <SirenSong>[
              for (final Object? row in value['songs'] as List)
                if (row is Map)
                  _songFromRemoteRow(
                    row.map(
                      (Object? key, Object? item) =>
                          MapEntry<String, Object?>('$key', item),
                    ),
                  ),
            ]
          : const <SirenSong>[];
      for (final SirenSong song in songs) {
        _songById[song.id] = song;
      }
      if (_albumInfoTitle.isEmpty) {
        _albumInfoTitle = _text(album['title'] ?? album['name']);
      }
      _albumInfoArtist = _text(album['artist']);
      _albumInfoCover = _text(album['cover']);
      _albumInfoDate = _text(album['date']);
      _albumInfoDescription = _text(album['description']);
      _albumInfoTrackCount = album['trackCount'] is num
          ? (album['trackCount'] as num).toInt()
          : songs.length;
      _albumInfoSongs = List<SirenSong>.unmodifiable(songs);
      _albumInfoLoading = false;
      _albumInfoStatus = '';
      _publish();
    } on Object catch (error) {
      if (_disposed || _albumInfoId != id) {
        return;
      }
      _albumInfoLoading = false;
      _albumInfoStatus = remoteErrorMessage(error);
      _publish();
    }
  }

  /// 塞壬平台的专辑信息：本地曲库有这张专辑就填真字段，没有就直说不提供。
  Future<void> _openLocalAlbumInfo(String id) async {
    final SirenAlbum? local = _catalogAlbumById(id);
    if (local == null) {
      _albumInfoLoading = false;
      _albumInfoStatus = '$providerName不提供专辑信息';
      _publish();
      return;
    }
    _albumInfoTitle = _albumInfoTitle.isEmpty ? local.name : _albumInfoTitle;
    _albumInfoArtist = local.artist;
    _albumInfoCover = local.cover;
    _albumInfoTrackCount = local.songCount;
    _albumInfoStatus = '正在读取专辑曲目…';
    _albumInfoLoading = true;
    _publish();
    try {
      final SirenAlbum detailed = await _repository.albumDetail(local);
      if (_disposed || _albumInfoId != id) {
        return;
      }
      for (final SirenSong song in detailed.songs) {
        _songById[song.id] = song;
      }
      _albumInfoSongs = List<SirenSong>.unmodifiable(detailed.songs);
      _albumInfoTrackCount = detailed.songCount > 0
          ? detailed.songCount
          : detailed.songs.length;
      _albumInfoLoading = false;
      _albumInfoStatus = '$providerName不提供发行信息';
      _publish();
    } on Object catch (error) {
      if (_disposed || _albumInfoId != id) {
        return;
      }
      _albumInfoLoading = false;
      _albumInfoStatus = remoteErrorMessage(error);
      _publish();
    }
  }

  /// 关掉专辑信息页（回到调用它的页面，不动播放/目录）。
  void closeAlbumInfo() {
    if (_disposed || _albumInfoId.isEmpty) {
      return;
    }
    _albumInfoId = '';
    _albumInfoTitle = '';
    _albumInfoArtist = '';
    _albumInfoCover = '';
    _albumInfoDate = '';
    _albumInfoDescription = '';
    _albumInfoTrackCount = 0;
    _albumInfoStatus = '';
    _albumInfoLoading = false;
    _albumInfoSongs = const <SirenSong>[];
    _publish();
  }

  SirenAlbum? _catalogAlbumById(String id) {
    for (final SirenAlbum album in _catalogAlbums) {
      if (album.id == id) {
        return album;
      }
    }
    return null;
  }

  /// 拉一次服务端歌单（插件平台 + 已登录才有效；塞壬/本地平台直接返回）。
  Future<void> refreshServerPlaylists({String uid = ''}) async {
    final ProviderGateway? gateway = _remoteSearch;
    if (gateway == null ||
        _disposed ||
        !gateway.operation('userPlaylists', fallback: false)) {
      return;
    }
    final int seq = ++_serverPlaylistSeq;
    try {
      final List<Map<String, Object?>> rows = await gateway.userPlaylists(
        uid: uid,
      );
      if (_disposed || seq != _serverPlaylistSeq) {
        return;
      }
      final List<BasicLocalPlaylist> playlists = <BasicLocalPlaylist>[
        for (final Map<String, Object?> row in rows)
          if (_text(row['kind']) != 'song')
            BasicLocalPlaylist(
              id: _text(row['id']),
              title: _text(row['title']),
              trackCount: row['trackCount'] is num
                  ? (row['trackCount'] as num).toInt()
                  : 0,
            ),
      ];
      _serverPlaylists = List<BasicLocalPlaylist>.unmodifiable(playlists);
      _publish();
    } on Object catch (error) {
      if (_disposed) {
        return;
      }
      _status = remoteErrorMessage(error);
      _publish();
    }
  }

  /// 远端喜欢的曲目行（拉 id 后按需 `songs(ids)` 解析成可画的行）。
  List<SirenSong> get serverLikedSongs => _serverLikedSongs;
  List<SirenSong> _serverLikedSongs = <SirenSong>[];

  /// 从服务端刷新「喜欢的歌曲」（插件平台才需要；本地平台直接返回）。
  ///
  /// 只在登录且有账号时调用：网易云的 `likedIDs(uid)` 需要一个 uid，
  /// 未登录会被上游回 400（真机探针确认过）。
  Future<void> refreshServerLiked({String uid = ''}) async {
    final ProviderGateway? gateway = _remoteSearch;
    if (gateway == null || _disposed) {
      return;
    }
    final int seq = ++_serverLikedSeq;
    try {
      final List<String> ids = await gateway.likedTrackIds(uid: uid);
      if (_disposed || seq != _serverLikedSeq) {
        return;
      }
      _serverLikedIds = <String>{
        for (final String id in ids)
          if (id.isNotEmpty) id,
      };
      _orderedServerLikedIds = <String>[
        for (final String id in ids)
          if (id.isNotEmpty) id,
      ];
      // 首批只解析 100 条（Qt `loadLikedIDs` 的 `slice(ids, likedCursor, 100)`）：
      // `songs(ids)` 一次传太多上游会拒；后续由 [loadMoreServerLiked] 续页。
      _serverLikedCursor = 0;
      _serverLikedSongs = const <SirenSong>[];
      await _loadServerLikedPage(gateway, seq);
      _publish();
    } on Object catch (error) {
      if (_disposed) {
        return;
      }
      _status = remoteErrorMessage(error);
      _publish();
    }
  }

  int _serverLikedSeq = 0;

  /// 远端曲目行 → `SirenSong`（插件字段没有 `durationMs`，`duration` 已经是毫秒）。
  ///
  /// 同时把原始行按 id 记进 [_remoteRows]：「↗ 歌手作品」要读 `artists[{id,name}]`，
  /// 那份嵌套字段落不进 [SirenSong] 的扁平结构。
  SirenSong _songFromRemoteRow(Map<String, Object?> row) {
    final String id = _text(row['id']);
    if (id.isNotEmpty) {
      _remoteRows[id] = row;
    }
    return SirenSong(
      id: id,
      title: _text(row['title']),
      artist: basicCleanArtist(_text(row['artist'])),
      album: _text(row['album']),
      albumId: _text(row['albumID']),
      cover: _text(row['cover']),
      sourceUrl: '',
      lyricUrl: '',
      durationMs: (row['duration'] is num
          ? (row['duration'] as num).toDouble()
          : 0),
    );
  }

  /// 跑一次远端检索（结果/失败原因都进 `_status`，与 Qt 的 `status` 一致）。
  Future<void> _runRemoteSearch() async {
    final ProviderGateway? gateway = _remoteSearch;
    if (gateway == null) {
      return;
    }
    final int seq = ++_remoteSearchSeq;
    final String kind = _searchKind;
    final String query = _query;
    final RemoteSearchResult result = await runRemoteSearch(
      gateway: gateway,
      kind: kind,
      query: query,
    );
    if (_disposed || seq != _remoteSearchSeq) {
      return;
    }
    _remoteSearchResult = result;
    _status = result.status;
    _publish();
  }

  /// 打开远端检索结果的第 [index] 行：先向插件要播放地址，再走正常打开流程。
  ///
  /// 返回空串 = 已打开；非空 = 可直接上屏的原因（没有音源、插件报错、越界）。
  Future<String> openRemoteSong(int index) async {
    final List<Map<String, Object?>> rows =
        _remoteSearchResult?.rows ?? const <Map<String, Object?>>[];
    if (_disposed || index < 0 || index >= rows.length) {
      return '该条目已不在列表里';
    }
    final Map<String, Object?> row = rows[index];
    final SirenSong song = SirenSong(
      id: _text(row['id']),
      title: _text(row['title']),
      artist: _text(row['artist']),
      album: _text(row['album']),
      albumId: _text(row['albumID']),
      cover: _text(row['cover']),
      sourceUrl: '',
      lyricUrl: '',
      durationMs: (row['durationMs'] as num?)?.toDouble() ?? 0,
    );
    final ProviderGateway? gateway = _remoteSearch;
    if (gateway == null) {
      return '当前平台不支持播放';
    }
    String source = '';
    try {
      source = await gateway.playback(
        trackId: song.id,
        quality: _remoteQuality,
      );
    } on ProviderUnavailableError catch (error) {
      return error.message;
    } on ProviderRequestError catch (error) {
      return error.message;
    } on Object catch (error) {
      return '取播放地址失败：$error';
    }
    if (source.isEmpty) {
      return '该曲目没有可用音源';
    }
    await openSong(song.copyWith(sourceUrl: source));
    return '';
  }

  SearchOutcome searchOutcome() {
    final String signature = <Object?>[
      _catalogGeneration,
      _query,
      _searchKind,
      _collectionsDigest(),
    ].join('|');
    final SearchOutcome? cache = _searchOutcomeCache;
    if (cache != null && signature == _searchOutcomeSignature) {
      return cache;
    }
    final CatalogSearchIndex index = CatalogSearchIndex(
      catalog: SirenCatalog(songs: _catalogSongs, albums: _catalogAlbums),
      playlists: _localPlaylists,
    );
    final SearchOutcome outcome = index.search(
      kind: _searchKind,
      query: _query,
    );
    _searchOutcomeSignature = signature;
    _searchOutcomeCache = outcome;
    return outcome;
  }

  /// 分组的成员列表（Qt `MusicLibrary::groupTitles` / `groupIndices` 的收窄投影）。
  ///
  /// 只有「曲目分类 + 分组键非 none + 已展开某个标题」时才非空；键是分组名
  /// （歌手名或专辑名），值是该组在 `searchOutcome().items` 里的**行下标**。
  /// 排序与 Qt `NativeHudSearch.cpp` 一致：先按条目数降序，再按标题升序。
  Map<String, List<int>> searchGroups() {
    if (_searchKind != catalogSearchKinds.first || _searchGroup == 'none') {
      return const <String, List<int>>{};
    }
    final SearchOutcome outcome = searchOutcome();
    final String field = _searchGroup == 'artist' ? 'artist' : 'album';
    final Map<String, List<int>> groups = <String, List<int>>{};
    for (int index = 0; index < outcome.items.length; index++) {
      final Map<String, Object?> item = outcome.items[index];
      if (_text(item['kind']) != 'song') {
        continue;
      }
      final String key = _text(item[field]);
      if (key.isEmpty) {
        continue;
      }
      groups.putIfAbsent(key, () => <int>[]).add(index);
    }
    final List<MapEntry<String, List<int>>> sorted = groups.entries.toList()
      ..sort((MapEntry<String, List<int>> a, MapEntry<String, List<int>> b) {
        final int byCount = b.value.length.compareTo(a.value.length);
        return byCount != 0 ? byCount : a.key.compareTo(b.key);
      });
    return <String, List<int>>{
      for (final MapEntry<String, List<int>> entry in sorted)
        entry.key: entry.value,
    };
  }

  /// 分组视图下要画的行（Qt `groupIndices` 生效时 `libraryItems()` 只返回该组）。
  ///
  /// 非分组态返回 null，宿主直接用 [searchOutcome]。
  List<Map<String, Object?>>? searchGroupRows() {
    final Map<String, List<int>> groups = searchGroups();
    if (groups.isEmpty || _searchGroupKey.isEmpty) {
      return null;
    }
    final List<int>? indices = groups[_searchGroupKey];
    if (indices == null || indices.isEmpty) {
      return null;
    }
    final SearchOutcome outcome = searchOutcome();
    return <Map<String, Object?>>[
      for (final int index in indices)
        if (index >= 0 && index < outcome.items.length) outcome.items[index],
    ];
  }

  /// 进入专辑（换列）：把专辑当成**目录**打开，留在资料库里显示它的曲目。
  ///
  /// Qt 的目录语义（Qt/src/MusicLibrary.cpp:843-869 `selectResult(index, lane, open=true)`）：
  /// ```
  /// const auto mode = open && lists[lane].at(index).toObject()["kind"] == "song" ? "detail" : "archive";
  /// emit modeRequested(mode);
  /// if (open && current.value("kind") != "song") enterDirectory(current);
  /// ```
  /// 也就是说**点专辑行 = 留在 archive 模式并进入该专辑目录**，只有点曲目行才进
  /// 详情（抽唱片）。旧实现把专辑行交给 [openAlbum]：相位跳到 detail、3D 抽出唱片、
  /// 列表变成「01 / 01」——正是用户 2026-11-19 报的「进入专辑内应该切换列而不是抽出
  /// 唱片」，同时也让单曲专辑的详情页一进去就只有一个当前行（用户报的「必然触发
  /// 自动打开详情」）。
  ///
  /// [play] 为 true（HUD 的『播放全部』）时只多一步：进列后按目录队列从第一首起播
  /// （Qt 的 `MusicLibrary::play()` 也是 replaceQueue + 从当前行播）。
  Future<void> enterAlbumColumn(SirenAlbum album, {bool play = false}) async {
    if (_disposed) {
      return;
    }
    final int generation = ++_detailGeneration;
    _status = sirenAlbumLoadingStatus;
    _loading = true;
    _publish();
    SirenAlbum detailed = album;
    try {
      final SirenAlbum fetched = await _repository.albumDetail(album);
      if (generation != _detailGeneration) {
        return;
      }
      if (fetched.songs.isNotEmpty) {
        detailed = fetched;
      }
    } on Object {
      // 详情拉不到就用曲库阶段按 albumCid 归组的那份（album.songs）：进列是浏览
      // 动作，不该因为一次网络失败把整页变成错误页。
    }
    if (generation != _detailGeneration) {
      return;
    }
    final List<SirenSong> songs = detailed.songs;
    for (final SirenSong song in songs) {
      _songById[song.id] = song;
    }
    ++_songGeneration;
    final String cover = detailed.cover.isNotEmpty
        ? detailed.cover
        : (songs.isEmpty ? '' : songs.first.cover);
    _directory = BasicDirectory(
      provider: sirenProvider,
      kind: 'album',
      id: detailed.id,
      key: detailed.key,
      title: detailed.name,
      artist: detailed.artist,
      cover: cover,
      // 上游专辑没有独立简介字段（siren.mjs:426-431 只回 songs/name/artist/cover），
      // 目录副标题就用同样的「艺人 / N 首」，不编造文案。
      description: detailed.artist,
      trackCount: songs.length,
      virtual: false,
      songs: songs,
      ids: <String>[for (final SirenSong song in songs) song.id],
      cursor: songs.length,
      index: 0,
      parent: _directory,
      parentLane: _selectedLane,
      parentSelection: _selection,
    );
    _album = null;
    _phase = BasicPhase.library;
    _query = '';
    _loading = false;
    _error = '';
    _status = '$sirenOpenedPrefix${detailed.name}';
    // 与 openAllSirenSongs 同一条：只选中第一首，不自动播（除非显式 play）。
    _song = songs.isEmpty ? null : songs.first;
    _selection = songs.isEmpty
        ? null
        : BasicSelection(kind: 'song', id: songs.first.id);
    _listPosition = 0;
    _publish();
    if (play && songs.isNotEmpty) {
      await openSong(songs.first);
    }
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

  /// 播放模式（Qt 动作 `player:mode:<off|all|one|shuffle>` 的落点）。
  ///
  /// 真值在 [MusicPlayer.mode]（白名单校验 + 落 play-mode 偏好），这里只把结果
  /// 同步进 [state] 供 HUD 选中态使用；非法取值由播放器拒绝并保持原样。
  String get queueMode => _player.mode;

  bool setQueueMode(String value) {
    if (_disposed) {
      return false;
    }
    bool accepted = _player.setMode(value);
    if (accepted) {
      _publish();
    }
    return accepted;
  }

  /// 选中队列第 [index] 行并播放（Qt 动作 `player:queue:<i>` → player.play(queue.at(i), index=i)）。
  Future<void> playQueueIndex(int index) async {
    if (_disposed) {
      return;
    }
    final List<Map<String, Object?>> items = _player.queue.items;
    if (index < 0 || index >= items.length) {
      return;
    }
    _player.play(items[index], queueIndex: index);
  }

  /// 移除队列第 [index] 行（Qt 动作 `player:remove:<i>`；当前曲目由播放器拒绝）。
  void removeFromQueue(int index) {
    if (_disposed) {
      return;
    }
    _player.removeFromQueue(index);
  }

  /// 清空待播（Qt 动作 `player:clear`；当前曲目继续播放）。
  void clearUpcoming() {
    if (_disposed) {
      return;
    }
    _player.clearUpcoming();
  }

  /// 偏好异步加载完成后的再次回填（play-history / play-mode）。
  ///
  /// 生产时序：[MusicPlayer] 比 `BasicSettingsRuntime.load()` 先建，构造时端口镜像
  /// 还是空的；设置读完再调这里，播放模式与历史才会是上次会话的存档。
  void resyncPreferences() {
    if (_disposed) {
      return;
    }
    _player.resyncPreferences();
    _publish();
  }

  /// 打开一条远端（插件平台）条目：发现页行、服务端歌单行都走这里。
  ///
  /// 字段来自插件返回的 `{id,title,artist,album,albumID,cover,duration}`，
  /// 播放地址在真正起播时由 `_startPlayback` 向网关现取（不在这里缓存）。
  Future<void> openRemoteTrack(
    Map<String, Object?> row, {
    bool play = true,
  }) async {
    if (_disposed) return;
    await openSong(_songFromRemoteRow(row), play: play);
  }

  /// 拉当前曲目的歌曲百科（Qt `body()` 的 overview 分支）。
  ///
  /// 只有插件平台有这条 operation；塞壬/本地不请求，直接留空由页面显示
  /// 「暂无歌曲百科」。过期回执按代数丢弃（连点两首时不能串台）。
  Future<void> _loadSongWiki(SirenSong song) async {
    final ProviderGateway? gateway = _remoteSearch;
    if (gateway == null || _disposed) {
      return;
    }
    final int generation = ++_songWikiGeneration;
    try {
      final Map<String, Object?> page = await gateway.wiki(trackId: song.id);
      if (_disposed || generation != _songWikiGeneration) {
        return;
      }
      _songWiki = _text(page['text']);
    } on Object {
      if (_disposed || generation != _songWikiGeneration) {
        return;
      }
      _songWiki = '';
    }
    _songWikiLoading = false;
    _publish();
  }

  Future<void> openSong(SirenSong song, {bool play = true}) async {
    if (_disposed) {
      return;
    }
    ++_songGeneration;
    _song = song;
    _songWiki = '';
    _songWikiLoading = _remoteSearch != null;
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
    unawaited(_loadSongWiki(song));
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
      source: <Map<String, Object?>>[
        for (final SirenSong item in source) item.toTrack(),
      ],
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
          : '$sirenReturnedPrefix$providerName';
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
    _status = _catalogLoaded ? _catalogLoadedStatus() : _libraryUnloadedStatus;
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
      _status = _libraryUnloadedStatus;
      _publish();
      return;
    }
    _openAllSirenDirectory();
    _publish();
  }

  // 列表选中 / 滚动 / 列切换（archive 手势与键盘的落点；一律不自动播放）

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
    final int index = row < 0 || row >= items.length
        ? basicSelectedItemIndex(_state, items)
        : row;
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
    _maybeLoadMoreServerLiked(row);
    await selectLibraryRow(row);
  }

  /// 滚到列表尾部附近就续页（Qt `MusicLibrary::loadMoreSource` 的滚动触发：
  /// `selectResult` 里 `if (index >= totals[lane] - 8) loadMoreSource(lane)`）。
  ///
  /// 只对插件平台「喜欢的歌曲」列生效：塞壬的喜欢来自本地集合，没有分页概念。
  void _maybeLoadMoreServerLiked(int row) {
    if (_remoteSearch == null || _selectedLane != 1 || _directory != null) {
      return;
    }
    final int total = _serverLikedSongs.length;
    if (!serverLikedHasMore || row < total - 8) {
      return;
    }
    unawaited(loadMoreServerLiked());
  }

  /// 列表拖动**过程中**的连续窗口位置（单位条目，可为小数）。
  ///
  /// 与 [commitLibraryScroll] 的分工就是 Qt 的 observe / select 分工：拖动中途窗口跟
  /// 手指走（可以是 72.6 这种小数），但"越过即进入"必须当场发生——Qt 的手势路径是
  /// `NativeScene::navigatePlane` 每跨一格就 `select(fileAt(cell))`
  /// （Qt/src/NativeSceneInput.cpp:97-115），而 HUD 每帧 `observe(frame["selected"])`
  /// （Qt/src/NativeApplication.cpp:138）。所以这里写窗口的同时把选中落到最近一行，
  /// 只是**不播、不换队列、不刷状态条**（那是 commit/显式点选的事）。
  void updateLibraryScroll(double position) {
    if (_disposed || position.isNaN || !position.isFinite) {
      return;
    }
    if ((position - _listPosition).abs() < 1e-4) {
      return;
    }
    _observeWindow(position);
  }

  /// 拖动中途的"越过即进入"：窗口保持小数（列表跟手），选中立刻落到最近一行。
  ///
  /// 与 [_selectRow] 的差别只有两处：`recordWindow: false`（不重算 8 行页偏移）和
  /// `announce: false`（不刷"已选中：…"），并且写回时把 [_listPosition] 还原成小数
  /// 位置，避免 `_selectRow` 的窗口吸附把列表钉在整行上（那正是"高亮跟着行跑、条目
  /// 不跳格"的旧缺陷）。目录里同一份真值由 [_syncDirectoryIndex] 跟着走。
  void _observeWindow(double position) {
    final List<BasicListItem> items = basicLibraryItems(_state);
    if (items.isEmpty) {
      _listPosition = position;
      _publish();
      return;
    }
    final double max = (items.length - 1).toDouble();
    final double clamped = position.clamp(0.0, max);
    if (_phase == BasicPhase.library) {
      final int row = clamped.round();
      final bool needsSelection =
          _selection == null || row != basicSelectedItemIndex(_state, items);
      if (needsSelection) {
        _selectRow(items, row, recordWindow: false, announce: false);
      }
    }
    if ((_listPosition - clamped).abs() > 1e-4) {
      _listPosition = clamped;
    }
    if (_directory == null &&
        _selectedLane >= 0 &&
        _selectedLane < _lanePositions.length) {
      // 记忆的是"窗口停在哪"，不是吸附后的整行（Qt observe 只折 anchor，不改窗口）。
      _lanePositions[_selectedLane] = _listPosition;
    }
    _maybeLoadMoreServerLiked(clamped.round());
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
    final int index = current == null
        ? -1
        : songs.indexWhere((SirenSong s) => s.id == current.id);
    final int next = index < 0
        ? 0
        : ((index + direction) % songs.length + songs.length) % songs.length;
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
  ///  - 中途就越过即进入（见 [updateLibraryScroll] 的同一份 observe 语义）：窗口保小数跟手，
  ///    选中当帧落到最近一行；松手（[committed]）才落定整数行并吃掉惯性回执。
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
    final double next = ((_nativeScrollOrigin ?? _listPosition) + deltaRows)
        .clamp(0.0, max);
    if (committed) {
      _nativeScrollOrigin = null;
      unawaited(commitLibraryScroll(next));
      return;
    }
    if ((next - _listPosition).abs() < 1e-4) {
      return;
    }
    // 3D 手势中途同样"越过即进入"：窗口小数跟手，选中当帧落到最近一行（[updateLibraryScroll]
    // 的同一份 observe 语义），松手才由 committed 分支落定并吃掉惯性回执。
    _observeWindow(next);
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

  /// 直接换到某一列（竖屏底栏/顶部 tab 点击）。
  ///
  /// 语义与 [navigateColumn] 的「无目录」分支逐条相同：只改 selectedLane 与该列
  /// 记住的行、只选中不播放、不换队列；越界就 no-op，不猜下标。
  Future<void> selectLane(int lane) async {
    if (_disposed || _directory != null || lane == _selectedLane) {
      return;
    }
    if (lane < 0 || lane >= _laneColumns.length) {
      return;
    }

    _showSourceLane(lane);
  }

  /// 切平台后把视图状态归零（Qt `MusicAccount::choose`，Qt/src/MusicAccount.cpp:200-330）。
  ///
  /// 这条是「插件平台列名与内容不匹配」的根因修复：Qt 换平台时会把
  /// `selectedLane` 归到 0（搜索结果列）、`searchKind` 回 `song`、`keyword` 清空、
  /// 各列 cursor/offset/rowMemory 一起归零；本仓库此前只换网关与列名，于是
  /// 插件平台仍停在塞壬的第 3 列，把塞壬曲库投影到「收藏歌单」上。
  void resetForProviderSwitch(List<String> columns) {
    if (_disposed) {
      return;
    }
    _laneColumns = columns.isEmpty ? basicSirenColumns : columns;
    _selectedLane = 0;
    _searchKind = catalogSearchKinds.first;
    _searchGroup = 'none';
    _searchGroupKey = '';
    _searchOutcomeCache = null;
    _searchOutcomeSignature = '';
    _listPosition = 0;
    _selection = null;
    // 同样是定长表：逐槽写零，列数变化时不重建（越界由 `_laneColumns.length` 守卫挡住）。
    for (int lane = 0; lane < _lanePositions.length; lane++) {
      _lanePositions[lane] = 0;
    }
    // `_laneOffsets`/`_rowMemory` 来自 `List<int>.filled`（定长，不能 remove/replaceRange），
    // 所以只能逐槽写零。
    for (int lane = 0; lane < _laneOffsets.length; lane++) {
      _laneOffsets[lane] = 0;
      _rowMemory[lane] = 0;
    }
    _serverLikedSongs = const <SirenSong>[];
    _serverPlaylists = const <BasicLocalPlaylist>[];
    _serverLikedCursor = 0;
    _orderedServerLikedIds = const <String>[];
    _publish();
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
    final int current = directory.index < 0 || directory.index >= songs.length
        ? 0
        : directory.index;
    final int next =
        ((current + step) % songs.length + songs.length) % songs.length;
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
    // 列数随平台走（插件 manifest 五列，塞壬五列）；用 _laneColumns.length 而不是
    // basicSirenColumns.length，否则将来列数不同的平台会被这里直接挡掉。
    if (lane < 0 || lane >= _laneColumns.length) {
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
        remote: _remoteSearch != null,
      );
      _publish();
      return;
    }
    // Qt showSource（Qt/src/MusicLibrary.cpp:566-573）恢复的是**滚动窗口的那一行**：
    //   physical = physicalSlots[lane].value(rowMemory[lane]); observe(physical)
    //   → 绝对行 = wrap(offsets[lane] + rowMemory[lane], count)
    // 不是“上次记住的选中身份”（那个可能已被 openSong/step 挪到别的窗口行）。
    final int count = items.length;
    final int row =
        (((_laneOffsets[lane] + _rowMemory[lane]) % count) + count) % count;
    // Qt showSource（Qt/src/MusicLibrary.cpp:556-580）只恢复 selectedPhysical/observe，
    // 不改 offsets/rowMemory —— 恢复一条记忆不能把该列的滚动窗口重算成 row%8。
    _selectRow(items, row, recordWindow: false);
    _status = '${_laneName(lane)}：${items.length} 项';
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
        final List<SirenSong> tracks =
            (_phase == BasicPhase.detail && album != null)
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
    if (_directory == null &&
        _selectedLane >= 0 &&
        _selectedLane < _rowMemory.length) {
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
  ///
  /// 2026-11-24 用户要求「歌词无需播放就能看」：选中曲目还没开播时，这里按
  /// [_ensurePreviewLyrics] 去取该曲目的歌词，面板画预览文本（无进度高亮）。
  Future<void> openLyrics() async {
    if (_disposed || _song == null) {
      return;
    }
    if (_phase != BasicPhase.lyrics) {
      _phaseBeforeLyrics = _phase;
      _phase = BasicPhase.lyrics;
      _publish();
    }
    final SirenSong? song = _song;
    if (song != null) {
      unawaited(_ensurePreviewLyrics(song));
    }
  }

  /// 取「未播放曲目」的歌词文本（预览）。
  ///
  /// 三条来源，顺序与播放路径一致：
  ///  1. 插件平台曲目 → `lyrics` operation（`gateway.lyricsByTrack`，参数是插件原始行；
  ///     没有原始行时退回 [SirenSong.toTrack]）；
  ///  2. 塞壬曲库曲目 → 曲目自带的 `lyricUrl`；
  ///  3. `lyricUrl` 为空（曲库列表行常常不带）→ 用 `songDetail` 现取一次。
  /// 同一首已经在取的不会重复发请求（代数号保证旧回执不覆盖新曲目）。
  Future<void> _ensurePreviewLyrics(SirenSong song) async {
    if (_disposed || song.id.isEmpty) {
      return;
    }
    if (_playingTrackOf()?.id == song.id) {
      // 正在播放的那首：播放路径已经装好了歌词，不需要预览副本。
      return;
    }
    if (_previewLyricId == song.id &&
        (_previewLyricStatus == 'loading' || _previewLyricStatus == 'ready')) {
      return;
    }
    final int generation = ++_previewLyricGeneration;
    _previewLyricId = song.id;
    _previewLyricDoc = BasicLyricsDocument.empty;
    _previewLyricStatus = 'loading';
    _previewLyricMessage = '';
    _publish();
    try {
      final ProviderGateway? gateway = _remoteSearch;
      Map<String, Object?>? document;
      String lyricUrl = song.lyricUrl;
      if (gateway != null) {
        document = await _fetchRemoteLyrics(
          gateway,
          _remoteRows[song.id] ?? song.toTrack(),
        );
      } else if (lyricUrl.isEmpty) {
        final SirenSongDetail detail = await _repository.songDetail(song.id);
        if (generation != _previewLyricGeneration || _disposed) {
          return;
        }
        _rememberDetail(detail);
        lyricUrl = detail.lyricUrl;
      }
      if (generation != _previewLyricGeneration || _disposed) {
        return;
      }
      BasicLyricsDocument parsed = BasicLyricsDocument.empty;
      if (document != null) {
        parsed = basicLyricsFromDocument(document);
      } else if (lyricUrl.isNotEmpty) {
        final String text = await _repository.lyricsText(lyricUrl);
        if (generation != _previewLyricGeneration || _disposed) {
          return;
        }
        if (text.trim().isNotEmpty && text.length <= sirenMaxLyricLength) {
          parsed = parseBasicLyrics(text);
        }
      }
      if (generation != _previewLyricGeneration || _disposed) {
        return;
      }
      if (parsed.isEmpty) {
        _previewLyricDoc = BasicLyricsDocument.empty;
        _previewLyricStatus = 'empty';
        _previewLyricMessage = sirenEmptyLyricsMessage;
      } else {
        _previewLyricDoc = parsed.lines.length > sirenMaxLyricLines
            ? BasicLyricsDocument(
                lines: parsed.lines.sublist(0, sirenMaxLyricLines),
                offsetMs: parsed.offsetMs,
                plainText: '',
                timed: true,
              )
            : parsed;
        _previewLyricStatus = 'ready';
        _previewLyricMessage = '';
      }
      _publish();
    } on Object catch (error) {
      if (generation != _previewLyricGeneration || _disposed) {
        return;
      }
      // 真实错误上屏（与播放路径同一口径），不吞成「无歌词」。
      _previewLyricDoc = BasicLyricsDocument.empty;
      _previewLyricStatus = 'empty';
      _previewLyricMessage = _messageOf(error);
      _publish();
    }
  }

  /// 清掉歌词预览（开播/换曲目时调用，避免「标题 A、歌词 B」）。
  void _clearPreviewLyrics() {
    if (_previewLyricId.isEmpty && _previewLyricStatus == 'idle') {
      return;
    }
    ++_previewLyricGeneration;
    _previewLyricId = '';
    _previewLyricDoc = BasicLyricsDocument.empty;
    _previewLyricStatus = 'idle';
    _previewLyricMessage = '';
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
    unawaited(
      media.sync(
        identity: BasicMediaIdentity(
          id: track.id,
          title: track.title,
          artist: track.artist,
          album: track.album,
          coverFilePath: cover,
        ),
        audio: _audio.state,
      ),
    );
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
        // 迟到的异常与迟到的成功一样危险：只有"这次异常仍属于当前身份"才允许清空
        // 封面。否则 A 的旧闭包在 B 已落图之后抛一次，就会把 B 的封面清成空。
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
  @override
  Future<void> seekToFraction(double fraction) async {
    if (_disposed || _player.current.isEmpty) {
      return;
    }
    final double clamped = fraction.isNaN
        ? 0
        : fraction.clamp(0.0, 1.0).toDouble();
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

  /// 歌词全局偏移的薄封装（Qt `player:lyrics-earlier/later/reset`，
  /// `ResponsiveLyrics.cpp:236-278` 的选项面板四条动作里的三条）。
  ///
  /// 状态文案照 Qt `NativeHudLyrics.cpp` 的口径：偏移值直接写进状态行，
  /// 让用户知道 0.2s 一次累计到了多少；底层夹取在 `LyricsController` 里。
  /// 应用内音量（0..1）：Qt 的 `player:volume-fraction:<f>` 直接落到 `QAudioOutput`，
  /// 这里落到 MediaPlayer 的 setVolume——只改本应用，不动系统音量。
  Future<void> setVolumeFraction(double fraction) async {
    final BasicAudioPort audio = _audio;
    if (_disposed || audio is! BasicAudioVolumePort) {
      return;
    }
    await (audio as BasicAudioVolumePort).setVolume(fraction.clamp(0.0, 1.0));
  }

  Future<String> shiftLyricsOffset(double deltaMs) async {
    final LyricsController? lyrics = _lyrics;
    if (lyrics == null) {
      return '歌词尚未加载';
    }
    lyrics.adjustOffset(deltaMs);
    _publish();
    return _lyricsOffsetStatus(lyrics);
  }

  /// 重置歌词偏移（Qt `player:lyrics-reset`）。
  Future<String> resetLyricsOffset() async {
    final LyricsController? lyrics = _lyrics;
    if (lyrics == null) {
      return '歌词尚未加载';
    }
    lyrics.resetOffset();
    _publish();
    return _lyricsOffsetStatus(lyrics);
  }

  /// 当前曲目的歌词偏移（毫秒）：「歌词偏移」浮层要按它决定按钮/灰字。
  double get lyricsOffsetMs => _lyrics?.offsetMs ?? 0;

  /// 全局歌词偏移（毫秒）：与当前偏移相等时「全局应用」只画灰字。
  double get lyricsGlobalOffsetMs => _lyrics?.globalOffsetMs ?? 0;

  /// 把当前偏移写成全局默认（Qt `player:lyrics-apply-global`）。
  Future<String> applyGlobalLyricsOffset() async {
    final LyricsController? lyrics = _lyrics;
    if (lyrics == null) {
      return '歌词尚未加载';
    }
    await lyrics.applyGlobalOffset();
    _publish();
    return '已应用到全局：${_lyricsOffsetStatus(lyrics)}';
  }

  static String _lyricsOffsetStatus(LyricsController lyrics) {
    final int offset = lyrics.offsetMs.round();
    if (offset == 0) {
      return '歌词偏移已重置';
    }
    final String sign = offset > 0 ? '+' : '';
    return '歌词偏移 $sign${offset}ms';
  }

  /// 下一首（队列由 MusicPlayer::next 推进，音源由引擎 fresh 读取）。
  @override
  Future<void> next() async {
    if (_disposed) {
      return;
    }
    _player.next(1);
    _publish();
  }

  /// 上一首。
  @override
  Future<void> previous() async {
    if (_disposed) {
      return;
    }
    _player.next(-1);
    _publish();
  }

  /// 竖屏详情页的「上一首 / 下一首」：在**详情页曲目所在的列表**里换曲并播放。
  ///
  /// 与 [previous]/[next]（推进播放队列，Qt 的 `player:prev/next`）刻意分开：
  /// 详情页展示的曲目不一定是当前队列的成员——用户在另一列或搜索结果里打开详情时，
  /// 队列还是上一次播放的那列。此时推进队列换掉的是**另一首歌的邻居**，与页面上
  /// 看到的曲目无关。详情页曲目同样是播放曲目时（当前曲目），页面仍走 [next]/
  /// [previous]，保留队列的随机/单曲循环语义。
  Future<void> playDetailSibling(int direction) async {
    if (_disposed || direction == 0) {
      return;
    }
    final SirenSong? song = _song;
    if (song == null) {
      return;
    }
    // 队列来源与「点播放」完全同一份：目录内是目录曲目、专辑内是专辑曲目、
    // 其余是当前可见列表（见 [_queueFor]）。两边用不同来源就会出现
    // 「页面上的下一首」与「播放后的下一首」对不上的怪象。
    final List<SirenSong> source = _queueFor(song);
    if (source.isEmpty) {
      return;
    }
    final int index = source.indexWhere((SirenSong item) => item.id == song.id);
    final int next = index < 0
        ? 0
        : ((index + direction) % source.length + source.length) % source.length;
    await openSong(source[next]);
  }

  /// 把当前详情曲目加入播放队列（Qt `music:enqueue` / `music:play-next`）。
  ///
  /// 真值：`Qt/src/NativeHudMusic.cpp:298-313` —— `music.player.enqueue(music.current,
  /// name == "play-next")`，成功回 `✓ 已加入队列` / `✓ 已设为下一首`，失败回
  /// `未能加入，请重试`。这里返回同一组文案，由宿主决定上屏。
  Future<String> enqueueCurrent({bool next = false}) async {
    if (_disposed) {
      return '未能加入，请重试';
    }
    final SirenSong? song = _song;
    if (song == null) {
      return '未能加入，请重试';
    }
    final bool queued = _player.enqueue(song.toTrack(), next: next);
    if (!queued) {
      return '未能加入，请重试';
    }
    _publish();
    return next ? '✓ 已设为下一首' : '✓ 已加入队列';
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

  // 曲库

  Future<void> _loadCatalog() async {
    final int generation = ++_catalogGeneration;
    _catalogLoaded = false;
    _loading = true;
    _error = '';
    _status = _catalogRetries > 0
        ? '$_catalogLoadingStatus（重试 $_catalogRetries/$maxCatalogRetries）'
        : _catalogLoadingStatus;
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
      _status = _catalogFailurePrefix + _error;
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
    _catalogRetryTimer = Timer(
      Duration(milliseconds: 400 * (1 << (attempt - 1))),
      () {
        if (_disposed || _catalogLoaded || !_booted) {
          return;
        }
        unawaited(_loadCatalog());
      },
    );
  }

  String _catalogLoadedStatus() {
    // 状态串里的平台名必须跟着当前平台走（Qt `providerName()`）：切到插件平台后
    // 再显示「已加载塞壬唱片曲库」是错的（用户报的「塞壬唱片：用搜索…」就是这一条）。
    final String name = providerName;
    if (_remoteSearch != null) {
      // 插件平台没有整库：说「已加载 936 首」会把塞壬的曲库数按到别的平台上。
      return '$name：用搜索查找曲目，收藏与歌单在左侧列';
    }
    return '已加载$name曲库：${_catalogSongs.length} 首 / ${_catalogAlbums.length} 张专辑';
  }

  /// 曲库读取中的状态串（Qt/src/MusicSiren.cpp:50 的模板，平台名跟着走）。
  String get _catalogLoadingStatus => '正在读取$providerName曲库…';

  /// 曲库读取失败的前缀（Qt/src/MusicSiren.cpp:63 的模板）。
  String get _catalogFailurePrefix => '$providerName曲库读取失败：';

  /// 曲库尚未加载的状态串（Qt/src/MusicSiren.cpp:195 的模板）。
  String get _libraryUnloadedStatus => '$providerName曲库尚未加载';

  /// 上游没有可播放音源时的文案（MusicBridge/client/siren.mjs:485 的模板）。
  String get _noSourceMessage => '$providerName未提供可播放音源';

  /// 当前远端平台的显示名（保留旧调用点；等同于 [providerName]）。
  String _providerDisplayName() => providerName;

  /// 资料库层的状态文案：目录打开时是目录标题（Qt MusicLibrary::libraryName()，
  /// Qt/src/MusicLibrary.cpp:189-194），否则是曲库加载结果。
  String _libraryStatus() {
    final BasicDirectory? directory = _directory;
    if (directory != null) {
      return '$sirenOpenedPrefix${directory.title}';
    }
    return _catalogLoaded ? _catalogLoadedStatus() : _libraryUnloadedStatus;
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
      artist: providerName,
      cover: songs.first.cover,
      description: '$providerName$sirenAllSongsTitleSuffix',
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
      final int index = parent.index < 0 || parent.index >= parent.songs.length
          ? 0
          : parent.index;
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
    final int index = directory.songs.indexWhere(
      (SirenSong item) => item.id == song.id,
    );
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
  /// 宿主读完本机收藏后调用（`LocalCollectionStore.load()` 是异步的，构造期读不到）。
  ///
  /// 等价于 Qt 的 `reloadSirenCollections()`：重新查询 liked/playlists 并重发状态。
  void refreshLocalCollections() {
    if (_disposed) {
      return;
    }
    _refreshLocalCollections();
    _searchOutcomeCache = null;
    _publish();
  }

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
      // 「搜索结果」列只放**当前分类**的命中项（Qt `lists[0]`）：
      // 曲目分类才列曲目，其余分类的行由分类检索页（laneItems → searchOutcome）
      // 承担，不能把全库曲目塞进歌单/歌手分类。
      if (_searchKind != catalogSearchKinds.first) {
        return const <SirenSong>[];
      }
      return filterSirenSongs(_catalogSongs, _query);
    }
    if (selected == 1) {
      // 「喜欢的歌曲」列：本机 likedIDs 经曲库解析出的曲目（Qt lists[1]）。
      // 插件平台走服务端收藏：Qt `MusicLibrary` 在 `likedIDs` 回来之后同样把它
      // 填进 `lists[1]`（`MusicLibrary.cpp:969-990`），所以这里分岔到服务端行。
      if (_remoteSearch != null) {
        return _serverLikedSongs;
      }
      return _likedSongs;
    }
    if (selected == 2) {
      // 「我的歌单」列的行是歌单（state.localPlaylists），这一列里没有曲目：
      // 不能把整库曲目塞进 state.songs，否则 state.song/播放面会指到不相干的曲目。
      return const <SirenSong>[];
    }
    if (_remoteSearch != null) {
      // 插件平台没有「整库」这一层：Qt 的 `sourceItems(lane)` 在插件平台只填收藏
      // （`lists[1]`）与歌单（`lists[2]`），其余列要么空、要么等 `loadMoreSource`。
      // 此前这里无条件返回 `_catalogSongs`，于是切到网易云后「收藏歌单」列里
      // 显示的是塞壬的 936 首曲目（用户报的「切平台后还有上一个平台的信息」）。
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
      // 专辑分类才在「搜索结果」列列专辑行（Qt 的 lists[0] 只承载一类条目）。
      if (_searchKind != 'album') {
        return const <SirenAlbum>[];
      }
      return filterSirenAlbums(_catalogAlbums, _query);
    }
    if (_remoteSearch != null) {
      // 同 `_visibleSongs`：插件平台不投影塞壬曲库的专辑。
      return const <SirenAlbum>[];
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
  /// 因真实内容变化而递增（ 的 apiAsks.for152_noSourceWritesBy153[0]）。
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
      // 插件平台的服务端歌单/喜欢来自网络：它们不参与 `_collectionsDigest()`，
      // 必须单独进签名，否则 lane 2 会一直命中上一份空表缓存。
      _serverPlaylists.length,
      _serverLikedSongs.length,
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
      serverPlaylists: _serverPlaylists,
      laneColumns: _laneColumns,
      // 插件平台：`basicLibraryItems` 的 lane 1/2 与空态文案都按这一位选数据源。
      searchRemote: _remoteSearch != null,
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

  // 播放：engine 端口实现（fresh 详情 → native prepare/play → playbackStarted）

  Future<void> _startPlayback(
    Map<String, Object?> track,
    int generation,
  ) async {
    _activeGeneration = generation;
    final LyricsController lyrics = await _ensureLyrics();
    if (_activeGeneration != generation) {
      // 等 LyricsController.create 期间已被新的 play 取代：旧的一份不许再写歌词状态。
      return;
    }
    lyrics.load(track);
    _lyricDoc = BasicLyricsDocument.empty;
    _clearPreviewLyrics();
    _publish();
    final String id = _text(track['id']);
    if (id.isEmpty) {
      _player.fail(_noSourceMessage, generation: generation);
      return;
    }
    try {
      // 远端（插件平台）曲目：播放地址已经由宿主向插件要过、随 track 一起传进来。
      // 这里**不能**再走 `_repository.songDetail`——那是塞壬的 id 空间，插件曲目
      // 的 id 在那边必然 404，真机表现就是「详情页打开、状态一直已暂停」。
      String sourceUrl = _text(track['sourceUrl']);
      String lyricUrl = '';
      // 插件平台的歌词走 `lyrics` operation（Qt/src/LyricsController.cpp:368-380 的
      // `api(provider).call("lyrics", {track})`），不是塞壬的 lyricUrl。
      Map<String, Object?>? remoteLyrics;
      if (sourceUrl.isEmpty) {
        final ProviderGateway? gateway = _remoteSearch;
        if (gateway != null) {
          // 插件平台的曲目（例如从「我的歌单」目录点进来的那一行）不带 sourceUrl，
          // 播放地址只能现向插件要；**不能**落到 `_repository.songDetail`——那是塞壬
          // 的 id 空间，插件 id 在那边必然 404（真机表现：详情页打开、状态「已暂停」）。
          sourceUrl = await gateway.playback(
            trackId: id,
            quality: _remoteQuality,
          );
          remoteLyrics = await _fetchRemoteLyrics(gateway, track);
        } else {
          final SirenSongDetail detail = await _repository.songDetail(id);
          if (_activeGeneration != generation) {
            return;
          }
          _rememberDetail(detail);
          sourceUrl = detail.sourceUrl;
          lyricUrl = detail.lyricUrl;
        }
      }
      if (sourceUrl.isEmpty) {
        _player.fail(_noSourceMessage, generation: generation);
        return;
      }
      await _audio.prepare(sourceUrl, generation: generation);
      await _audio.play(generation: generation);
      // 真正开始播放（前台 Activity）时才拉起前台媒体服务；返回值只表示平台
      // 接受请求，通知是否可见取决于 POST_NOTIFICATIONS，失败不影响播放。
      unawaited(_mediaSession?.ensureStarted() ?? Future<bool>.value(false));
      _player.playbackStarted(generation: generation);
      if (remoteLyrics != null) {
        _applyRemoteLyrics(track, remoteLyrics);
      } else {
        unawaited(
          _loadLyrics(track, LyricsController.trackKey(track), lyricUrl),
        );
      }
    } on Object catch (error) {
      _player.fail(_messageOf(error), generation: generation);
    }
  }

  void _rememberDetail(SirenSongDetail detail) {
    final SirenSong? cached = _songById[detail.id];
    final SirenSong seed =
        cached ??
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

  /// 向插件要歌词；没有 `lyrics` 能力或出错时返回 null（走空态，不假装有词）。
  Future<Map<String, Object?>?> _fetchRemoteLyrics(
    ProviderGateway gateway,
    Map<String, Object?> track,
  ) async {
    if (!gateway.operation('lyrics', fallback: false)) {
      return null;
    }
    try {
      return await gateway.lyricsByTrack(track);
    } on Object catch (error) {
      if (error is ProviderUnavailableError || error is ProviderRequestError) {
        return null;
      }
      return null;
    }
  }

  /// 把插件歌词文档灌进域控制器（含 `translation` 行，Qt 面板同样消费这个字段）。
  void _applyRemoteLyrics(
    Map<String, Object?> track,
    Map<String, Object?> document,
  ) {
    final BasicLyricsDocument parsed = basicLyricsFromDocument(document);
    if (parsed.isEmpty) {
      final LyricsController? lyrics = _lyrics;
      if (lyrics != null) {
        _applyEmptyLyrics(lyrics);
      }
      return;
    }
    _lyricDoc = parsed;
    final LyricsController? lyrics = _lyrics;
    if (lyrics != null) {
      lyrics.accept(
        parsed.toLyricsDocument(source: _providerDisplayName()),
        track,
      );
      lyrics.sync(_number(_player.state['position']));
    }
    _publish();
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
    final LyricsController controller = await LyricsController.create(
      _MemoryLyricsPreferences(),
    );
    if (_disposed) {
      return controller;
    }
    controller.addListener(_onLyricsChanged);
    _lyrics = controller;
    return controller;
  }

  // 轮询与状态发布

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
    // 预览态 = 面板上挂着某首**未播放**曲目的歌词；播放曲目自己的歌词走 _lyricDoc。
    final bool previewing =
        _previewLyricId.isNotEmpty && _playingTrackOf()?.id != _previewLyricId;
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
      lyrics: previewing ? _previewLyricDoc.lines : _lyricDoc.lines,
      // 预览没有播放进度，高亮行恒为 -1（`_lyricsRows` 会按 -1 画成「无当前句」）。
      lyricIndex: previewing ? -1 : (lyrics?.index ?? -1),
      lyricsPreviewId: previewing ? _previewLyricId : '',
      dark: _dark,
      queue: <SirenSong>[
        for (final Map<String, Object?> track in _player.queue.items)
          _songFromTrack(track),
      ],
      queueIndex: _player.queue.index,
      queueMode: _player.mode,
      searchKind: _searchKind,
      searchGroup: _searchGroup,
      searchGroupKey: _searchGroupKey,
      // 服务端歌单/喜欢也进真实快照：HUD 画的是 `_state`，只填 `_probeState`
      // 会让 lane 2 有计数却没有行（真机现象：标题「我的歌单：30 项」、列表空白）。
      serverPlaylists: _serverPlaylists,
      laneColumns: _laneColumns,
      searchRemote: _remoteSearch != null,
      searchRows: _remoteSearch != null
          ? (_remoteSearchResult?.rows ?? const <Map<String, Object?>>[])
          : searchOutcome().items,
      searchTotal: _remoteSearch != null
          ? (_remoteSearchResult?.total ?? 0)
          : searchOutcome().total,
      searchStatus: _remoteSearch != null
          ? (_remoteSearchResult?.status ?? '')
          : searchOutcome().status,
      searchGroups: searchGroups(),
      lyricStatus: previewing
          ? _previewLyricStatus
          : (lyrics?.status ?? 'idle'),
      lyricMessage: previewing ? _previewLyricMessage : (lyrics?.message ?? ''),
      lyricsOffsetMs: lyrics?.offsetMs ?? 0,
      lyricsGlobalOffsetMs: lyrics?.globalOffsetMs ?? 0,
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
      title: _text(track['title']).isEmpty
          ? sirenUnknownTitle
          : _text(track['title']),
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

/// MusicPlayer 的媒体宿主端口：命令转发给底层音频端口，状态读它的真实快照。
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
    // 通知栏/MediaSession 的上报归 （platform_playback.dart 文件头已约定）；
    // 这里不做第二次上报，避免一条暂停写两次。
  }
}

/// PlaybackEnginePort：MusicPlayer 的 prepare 入口，委托给 controller 的 fresh 解析。
class _BasicPlaybackEngine implements PlaybackEnginePort {
  _BasicPlaybackEngine(this._owner);

  final BasicController _owner;

  @override
  void prepare(
    Map<String, Object?> track,
    int generation, {
    bool reload = false,
  }) {
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
