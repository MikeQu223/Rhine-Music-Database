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

/// 详情读取中的状态文案：Qt/src/MusicLibrary.cpp:138 的模板
/// '正在读取' + columns[lane] + '，请稍候…'，列名取 :27 的 '全部专辑'。
const String sirenAlbumLoadingStatus = '正在读取全部专辑，请稍候…';

/// 上游没有可播放音源时的文案（MusicBridge/client/siren.mjs:485）。
const String sirenNoSourceMessage = '塞壬唱片未提供可播放音源';

/// 无歌词时的文案（Qt/src/LyricsController.cpp:281）。
const String sirenEmptyLyricsMessage = '暂无歌词';

/// 歌词时间轴最多接受的行数（lib/domain/lyrics/lyrics_timeline.dart 的
/// validLyricsDocument 上限 5000；超出部分不参与时间轴）。
const int sirenMaxLyricLines = 5000;

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
  SirenSong? _song;
  BasicPhase? _phaseBeforeLyrics;
  bool _catalogLoaded = false;
  bool _booted = false;
  bool _disposed = false;

  /// 曲库 / 详情 / 播放三类异步的世代号；迟到响应整份丢弃
  /// （Qt 用 MusicApi::send 的 valid(generation) 做同一件事，Qt/src/MusicApi.cpp:98-100）。
  /// 选曲不需要独立世代号：换曲的迟到防护由 play 的 generation 经 _activeGeneration 承担。
  int _catalogGeneration = 0;
  int _detailGeneration = 0;
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
    _query = value;
    _error = '';
    if (!_catalogLoaded) {
      if (!_loading) {
        _status = sirenLibraryUnloadedStatus;
      }
      _publish();
      return;
    }
    final int count = _visibleSongs().length + _visibleAlbums().length;
    if (value.trim().isEmpty) {
      _status = _catalogLoadedStatus();
    } else if (count == 0) {
      _status = '没有匹配的音乐';
    } else {
      _status = '找到 $count 条结果';
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
  Future<void> openSong(SirenSong song) async {
    if (_disposed) {
      return;
    }
    _song = song;
    _phase = BasicPhase.detail;
    _loading = false;
    _error = '';
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

  /// 返回：歌词页回上一页；详情页回曲库（正在播放的歌不中断，Qt 的 lane 回退同义）。
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
      _album = null;
      _phase = BasicPhase.library;
      _loading = false;
      _error = '';
      _status = _catalogLoaded ? _catalogLoadedStatus() : sirenLibraryUnloadedStatus;
      _publish();
    }
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
      //
      // 已知的短暂回跳（reviewer S3）：native 回报新位置前，下一拍 _pump 仍会用旧 position
      // 再 sync 一次，index 可能先回到旧行再跳到目标行。这里不引入「本地目标位置」覆盖，
      // 因为 BASIC-89 契约 7 要求 seek 后立即重算、而位置只许来自 native；两害相权保留
      // 立即重算，等 native 读数到达即自愈（Qt/src/MusicPlayer.cpp:548-558 本身不做先行 sync）。
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

  List<SirenSong> _visibleSongs() {
    if (_phase == BasicPhase.detail && _album != null) {
      return _album!.songs;
    }
    return filterSirenSongs(_catalogSongs, _query);
  }

  List<SirenAlbum> _visibleAlbums() => filterSirenAlbums(_catalogAlbums, _query);

  /// 选曲时构造的队列：专辑详情内用详情曲目顺序，其余用当前过滤后的曲库顺序。
  List<SirenSong> _queueFor(SirenSong song) {
    final SirenAlbum? album = _album;
    if (album != null && album.id == song.albumId && album.songs.isNotEmpty) {
      return album.songs;
    }
    final List<SirenSong> visible = filterSirenSongs(_catalogSongs, _query);
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
    if (_disposed || _activeGeneration != generation) {
      // 等 LyricsController.create 期间被新的 play 取代或控制器已销毁：旧的一份不许再写歌词状态。
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
      if (_disposed || _activeGeneration != generation) {
        return;
      }
      _rememberDetail(detail);
      if (detail.sourceUrl.isEmpty) {
        _player.fail(sirenNoSourceMessage, generation: generation);
        return;
      }
      await _audio.prepare(detail.sourceUrl, generation: generation);
      if (_disposed || _activeGeneration != generation) {
        // prepare 期间被换代/销毁：不再发 play，也不写 playbackStarted（Qt MusicApi.cpp:98-100 的 valid 语义）。
        return;
      }
      await _audio.play(generation: generation);
      if (_disposed || _activeGeneration != generation) {
        return;
      }
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
    if (_disposed) {
      return;
    }
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
    _syncSongFromPlayer();
    _publish();
  }

  void _onLyricsChanged() => _publish();

  void _onAudioStateChanged(BasicAudioState state) => _publish();

  void _syncSongFromPlayer() {
    final Map<String, Object?> current = _player.current;
    final String id = _text(current['id']);
    if (id.isEmpty || id == _song?.id) {
      return;
    }
    _song = _songById[id] ?? _songFromTrack(current);
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
      song: _song,
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
