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
import 'basic_models.dart';
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
class BasicController extends ChangeNotifier {
  BasicController({
    required BasicAudioPort audio,
    SirenRepository? repository,
    bool dark = true,
  })  : _audio = audio,
        _repository = repository ?? SirenRepository(),
        _ownsRepository = repository == null,
        _dark = dark {
    _state = BasicViewState(dark: dark);
    _player = MusicPlayer(
      media: _BasicMediaHost(this),
      preferences: _MemoryPreferences(),
      engine: _BasicPlaybackEngine(this),
      provider: _providerName,
    );
    _player.addListener(_onPlayerChanged);
    _audio.addListener(_onAudioStateChanged);
  }

  static String _providerName() => sirenProvider;

  final BasicAudioPort _audio;
  final SirenRepository _repository;
  final bool _ownsRepository;
  final bool _dark;

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
  double _listPosition = 0;

  /// 当前资料库列（Qt `MusicLibrary::selectedLane`，Qt/src/MusicLibrary.cpp:167 起）：
  /// 根页列表只承载这一列，←/→ 按 [basicSirenSourceOrder] 循环换列。
  int _selectedLane = basicDefaultLane;

  /// 每列各自的滚动窗口（Qt 的 `offsets[lane]`，单位条目）与选中身份
  /// （Qt 的 `rowMemory[lane]` / `selectedPhysical` 投影）：换列再换回来时恢复位置。
  final List<double> _lanePositions = List<double>.filled(basicSirenColumns.length, 0);
  final List<BasicSelection?> _laneSelections =
      List<BasicSelection?>.filled(basicSirenColumns.length, null);
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
      _status = basicLaneEmptyNotice(basicSearchLane);
      _laneSelections[basicSearchLane] = null;
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
    final List<BasicListItem> items = basicLibraryItems(_state);
    if (items.isEmpty) {
      return;
    }
    final int count = items.length;
    final int current = basicSelectedItemIndex(_state, items);
    final int next = ((current + direction) % count + count) % count;
    _selectRow(items, next);
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
    _directory = directory.copyWith(index: next);
    _song = song;
    _selection = BasicSelection(kind: 'song', id: song.id);
    // Qt selectDirectory：`cell = (index + anchor) % 40; selectedLane = cell / 8`。
    // 基础版没有页内 anchor 模型，用 index % 40 的同一算式（5 列 × 8 行）。
    _selectedLane = _directoryLaneOf(next);
    _listPosition = next.toDouble();
    _lanePositions[_selectedLane] = _listPosition;
    _laneSelections[_selectedLane] = _selection;
    _status = '已选中：${song.title}';
    _publish();
  }

  /// 目录内某一行落在哪一列（Qt selectDirectory 的 `cell / 8`，5×8 网格）。
  int _directoryLaneOf(int index) {
    final int cell = ((index % 40) + 40) % 40;
    return cell ~/ 8;
  }

  /// 换列（Qt MusicLibrary::showSource，Qt/src/MusicLibrary.cpp:556-580）：
  /// 写 selectedLane、恢复该列记住的行、**只选中不播放**；列为空时诚实空态。
  ///
  /// 与 Qt 的差异只有一处并已在报告登记：Qt 会为账号列 loadMoreSource，基础版账号工作
  /// 暂停，lane 1/2 显示空态文案而不是发请求。
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
      _laneSelections[lane] = null;
      _status = basicLaneEmptyNotice(lane);
      _publish();
      return;
    }
    // 恢复该列上次选中的那一行（Qt rowMemory[lane] → physicalSlots → observe）；
    // 没有记忆时落回该列记住的滚动窗口，再退到第一行。
    int row = 0;
    final BasicSelection? remembered = _laneSelections[lane];
    if (remembered != null) {
      final int found = basicSelectedItemIndex(
        _probeState(selection: remembered, lane: lane),
        items,
      );
      if (found >= 0 && found < items.length) {
        row = found;
      }
    } else {
      final double stored = _lanePositions[lane];
      final int last = items.length - 1;
      row = stored.isNaN ? 0 : stored.round().clamp(0, last).toInt();
    }
    _selectRow(items, row);
    _status = '${basicLaneName(lane)}：${items.length} 项';
    _publish();
  }

  /// 把一行变成当前选中：只写选中身份与目录高亮，不碰 [_player]。
  ///
  /// 专辑行只改选中身份，不打开详情（Qt 的 selectResult(..., highlightOnly) 不改 mode）；
  /// 详情由 'open' 路径（[openSong]/openAlbum）负责。
  void _selectRow(List<BasicListItem> items, int row) {
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
    _lanePositions[_selectedLane] = _listPosition;
    _laneSelections[_selectedLane] = _selection;
    _status = '已选中：${item.title}';
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
  void pumpForTest(double seconds) => _pump(seconds);

  @override
  void dispose() {
    if (_disposed) {
      return;
    }
    _disposed = true;
    _ticker?.cancel();
    _ticker = null;
    _clock.stop();
    _player.removeListener(_onPlayerChanged);
    _lyrics?.removeListener(_onLyricsChanged);
    _audio.removeListener(_onAudioStateChanged);
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
    _status = sirenCatalogLoadingStatus;
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
      _catalogLoaded = true;
      _loading = false;
      _error = '';
      _status = _catalogLoadedStatus();
      _phase = BasicPhase.library;
    } on Object catch (error) {
      if (generation != _catalogGeneration) {
        return;
      }
      _loading = false;
      _catalogLoaded = false;
      _error = _messageOf(error);
      _status = sirenCatalogFailurePrefix + _error;
      _phase = BasicPhase.library;
    }
    _publish();
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
    // 目录内的 ±8 才走 _navigateDirectoryBy 的 cell/8（Qt selectDirectory）。
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
      if (restored != null) {
        _selection = restored;
        if (restored.isSong) {
          final SirenSong? song = _songById[restored.id];
          if (song != null) {
            _song = song;
          }
        }
      }
    }
    if (parent != null && parent.songs.isNotEmpty) {
      final int index =
          parent.index < 0 || parent.index >= parent.songs.length ? 0 : parent.index;
      _song = parent.songs[index];
      _selection = BasicSelection(kind: 'song', id: _song!.id);
      _listPosition = _rowOfSelection(_selection).toDouble();
    } else {
      _listPosition = _lanePositions[_selectedLane];
    }
    _lanePositions[_selectedLane] = _listPosition;
    _laneSelections[_selectedLane] = _selection;
    return parent;
  }

  /// 目录内选曲时同步高亮位置（Qt/src/MusicDirectory.cpp:302-319 selectDirectory：
  /// 先把 directory->index 写成被点行，再 choose 该项）。
  void _syncDirectoryIndex(SirenSong song) {
    final BasicDirectory? directory = _directory;
    if (directory == null) {
      return;
    }
    final int index =
        directory.songs.indexWhere((SirenSong item) => item.id == song.id);
    if (index < 0 || index == directory.index) {
      return;
    }
    _directory = directory.copyWith(index: index);
  }

  List<SirenSong> _visibleSongs() {
    final BasicDirectory? directory = _directory;
    if (directory != null) {
      // Qt/src/MusicLibrary.cpp:212-214：`directory ? directory->orderedSongs() : …`。
      // sortField 默认 'none'（MusicDirectory.cpp:9-19），顺序就是 songs 原序。
      return directory.songs;
    }
    if (_phase == BasicPhase.detail && _album != null) {
      return _album!.songs;
    }
    if (_selectedLane == basicSearchLane) {
      // 「搜索结果」列只列本次检索命中的曲目（Qt lists[0]）。
      return filterSirenSongs(_catalogSongs, _query);
    }
    return _catalogSongs;
  }

  List<SirenAlbum> _visibleAlbums() {
    if (_directory != null) {
      // 目录里只列曲目（Qt libraryItems() 的 directory 分支），专辑行不再出现。
      return const <SirenAlbum>[];
    }
    if (_phase == BasicPhase.detail && _album != null) {
      return const <SirenAlbum>[];
    }
    if (_selectedLane == basicSearchLane) {
      return filterSirenAlbums(_catalogAlbums, _query);
    }
    return _catalogAlbums;
  }

  /// 探针状态：只为复用 [basicLibraryItems] / [basicSelectedItemIndex] 的映射规则，
  /// 让 controller 的选中落点与 HUD 绘制/命中共用**同一份**列表真值。
  BasicViewState _probeState({BasicSelection? selection, int? lane}) {
    return BasicViewState(
      phase: _phase,
      query: _query,
      selectedLane: lane ?? _selectedLane,
      songs: _visibleSongs(),
      albums: _visibleAlbums(),
      album: _album,
      directory: _directory,
      song: _song,
      selection: selection ?? _selection,
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
    );
    notifyListeners();
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
