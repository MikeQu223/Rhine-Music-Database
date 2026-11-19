/// Qt -> Flutter 迁移 · MV 状态机。
///
/// Qt 移植源：`Qt/src/MvController.cpp`（702 行）
///   :12-24     构造：`// Deliberately no QAudioOutput: the MV must never duplicate the
///              music audio.`（本类因此只有静音，没有音频通道）
///   :49         sync 定时器 `m_timer.setInterval(250)`
///   :101-109    构造末尾读 `mv-offsets` / `mv-versions` / `mv-auto`
///   :182-199    setEnabled（写 `mv-auto` 为 "on"/"off"，然后 refresh(true)）
///   :442-460    versionLabels()（拼法已由 ProviderMvVersion.label 复刻）
///   :462-472    versionIndex()：选择表 → 回落 requestedMvID/m_mvID → 找不到 -1
///   :474-495    setVersionIndex()：选择表 trim 256、写 `mv-versions`、同项只发信号
///   :553-556    retry() == refresh(true)
///   :561-630    refresh(bool force)：键 `provider+':'+id`、generation/epoch 防串、
///               supported = capabilities.mv && operations.mv，以及三段基础状态串
///   :636-671    resolveVideo：`正在加载视频版本…` → `MV 加载失败：`+error /
///               `此歌曲没有关联 MV，可手动选择视频版本` / `MV 播放地址无效` /
///               `静音跟随音乐 · Np`
///   :673-676    音频位置的单调时钟记账
///   :677-702    sync()：音乐位置 + 偏移，`> playing ? 400 : 100` 才 setPosition
///
/// 纯 Dart：不 import flutter、不 import lib/data，偏好只走注入的 [PreferencePort]
/// （与 `lib/domain/player/music_player.dart:45` 同名同形；键是 Qt 的裸键，不加前缀，
/// 前缀属于数据层）。地址校验/状态串/seek 阈值复用
/// `lib/domain/mv/mv_track_validator.dart`，本文件不写第二份。
///
/// 移动端差异（唯一允许偏离 Qt 的地方，逐条写清）：
/// - Qt 的 `m_host->epoch`（数据源重建计数）在 Flutter 侧没有宿主字段，本类用
///   [MvController.invalidate] 显式推进 epoch，复刻"数据源换了就丢掉迟到回调"；
/// - Qt 用 QMediaPlayer 真解码；Android 侧没有解码器，[MvState.rendered] 恒 false，
///   面板据此画 `本机未接入视频解码`（诚实降级，不伪造播放）；
/// - `mv-auto` 缺键时按"默认开启"（Qt 缺键读 `preference()` 得空串 ⇒ 关；移动端点进来
///   就该看到 MV 面板，所以缺省取 on。**这是唯一一条与 Qt 不同的偏好缺省值**）；
/// - 网关 `mv({versionId})` 契约比 Qt 的"整份 track + videoID"窄：没有选中版本时
///   回落传曲目 id，平台侧把它当默认版本；并且用**id 与 url 都为空**的
///   [ProviderMvTrack] 表示"本曲没有关联 MV"（Qt :654 的 `!reply.value.isObject()`）；
/// - 动作串（`mv:*`）在 Qt 移动端不存在（`Qt/src/NativeHudController.cpp:358-359`
///   的 `if (name == "mv" && PlatformFeatures::MusicVideo)` 在手机上恒不触发，
///   `Qt/src/PlatformFeatures.h:23-27` 的 `MusicVideo = !RHINE_MOBILE && (...)`），
///   统一集中在文件末尾的 [MvAction]，本文件是唯一作者。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import '../../provider/provider_gateway.dart';
import '../player/music_player.dart' show PreferencePort;
import 'mv_track_validator.dart';

/// MV 面板的阶段。
enum MvPhase {
  /// 还没开始（没有曲目 / 已 [MvController.close]）。
  idle,

  /// 正在查找 MV 或正在加载视频版本（Qt 的两段 `正在…`）。
  searching,

  /// 版本列表可用但还没有可播放的关联 MV（Qt `此歌曲没有关联 MV，可手动选择视频版本`）。
  versions,

  /// 已拿到合法播放地址（Qt `静音跟随音乐 · Np`；手机上渲染降级）。
  playing,

  /// 当前来源不支持 MV（塞壬 descriptor `capabilities.mv=false` 的默认路径）。
  unsupported,

  /// 请求失败 / 地址非法。
  failed,
}

/// MV 面板的完整快照（不可变）。
class MvState {
  const MvState({
    this.trackId = '',
    this.phase = MvPhase.idle,
    this.status = '',
    this.track,
    this.versions = const <ProviderMvVersion>[],
    this.selectedVersionId = '',
    this.muted = true,
    this.offsets = const <String, int>{},
    this.resolution = 0,
    this.auto = true,
    this.versionStatus = '',
  });

  /// 当前曲目 id（Qt `track["id"]`）。
  final String trackId;

  /// 阶段。
  final MvPhase phase;

  /// 状态串（Qt `m_status`；UI 原样显示，不做翻译层）。
  final String status;

  /// 已解析到的播放信息；未就绪为 null。
  final ProviderMvTrack? track;

  /// 版本列表（Qt `m_versions`）。
  final List<ProviderMvVersion> versions;

  /// 当前选中的版本 id（Qt 选择表的 value；空串 = 未选）。
  final String selectedVersionId;

  /// 是否静音（Qt 刻意不建 QAudioOutput，恒 true）。
  final bool muted;

  /// 画面偏移表（Qt `m_offsets`，键是 MV id，值毫秒）。
  final Map<String, int> offsets;

  /// 分辨率（Qt `mv["resolution"]`，0 = 未知）。
  final int resolution;

  /// 是否自动查找（Qt `m_enabled` / 偏好 `mv-auto`）。
  final bool auto;

  /// 版本列表的附注（Qt `m_versionStatus`）。
  final String versionStatus;

  /// 是否有渲染器：Android 侧恒 false（本机未接入视频解码）。
  bool get rendered => false;

  /// 版本列表是否已到。
  bool get hasVersions => versions.isNotEmpty;

  /// 复制并替换字段（[track] 用 [withTrack]，因为这里无法表达"清空"）。
  MvState copyWith({
    String? trackId,
    MvPhase? phase,
    String? status,
    List<ProviderMvVersion>? versions,
    String? selectedVersionId,
    bool? muted,
    Map<String, int>? offsets,
    int? resolution,
    bool? auto,
    String? versionStatus,
  }) {
    return MvState(
      trackId: trackId ?? this.trackId,
      phase: phase ?? this.phase,
      status: status ?? this.status,
      track: track,
      versions: versions ?? this.versions,
      selectedVersionId: selectedVersionId ?? this.selectedVersionId,
      muted: muted ?? this.muted,
      offsets: offsets ?? this.offsets,
      resolution: resolution ?? this.resolution,
      auto: auto ?? this.auto,
      versionStatus: versionStatus ?? this.versionStatus,
    );
  }

  /// 替换（或清空）播放信息；分辨率跟着 track 走。
  MvState withTrack(ProviderMvTrack? value) => MvState(
        trackId: trackId,
        phase: phase,
        status: status,
        track: value,
        versions: versions,
        selectedVersionId: selectedVersionId,
        muted: muted,
        offsets: offsets,
        resolution: value?.resolution ?? 0,
        auto: auto,
        versionStatus: versionStatus,
      );
}

/// 选择表的容量上限（Qt/src/MvController.cpp:485-492 的 256）。
const int mvSelectionCap = 256;

/// 偏移表的容量上限（Qt/src/MvController.cpp:527-534 的 256）。
const int mvOffsetCap = 256;

/// 偏好键（Qt 的裸键；前缀由数据层加）。
const String mvAutoPreferenceKey = 'mv-auto';

/// 偏好键：版本选择表（`provider:trackId` → 版本 id）。
const String mvVersionsPreferenceKey = 'mv-versions';

/// 偏好键：画面偏移表（MV id → 毫秒）。
const String mvOffsetsPreferenceKey = 'mv-offsets';

/// Qt 的时间轴对齐间隔（`Qt/src/MvController.cpp:49` 的 `setInterval(250)`）。
///
/// 域层没有定时器：宿主每 250ms 调一次 [MvController.syncToMusic]，本常量只给宿主取用。
const Duration mvSyncInterval = Duration(milliseconds: 250);

/// MV 状态机：找片 → 版本列表 → 地址校验 → 静音跟随音乐。
class MvController {
  MvController({
    required PreferencePort preferences,
    DateTime Function()? clock,
    void Function(MvState state)? onChanged,
  })
      :
        // ignore: prefer_initializing_formals
        _preferences = preferences,
        _clock = clock ?? DateTime.now,
        // ignore: prefer_initializing_formals
        _onChanged = onChanged {
    // Qt/src/MvController.cpp:101-109 构造末尾的三次读偏好。
    final String autoRaw = _preferences.read(mvAutoPreferenceKey);
    _auto = autoRaw.isEmpty || autoRaw == 'on';
    _selections = _decodeMap(_preferences.read(mvVersionsPreferenceKey));
    _offsets = _decodeOffsetMap(_preferences.read(mvOffsetsPreferenceKey));
    _state = MvState(auto: _auto, offsets: Map<String, int>.of(_offsets));
  }

  final PreferencePort _preferences;
  final DateTime Function() _clock;
  final void Function(MvState state)? _onChanged;

  ProviderGateway? _gateway;
  bool _supported = false;
  bool _supportsVersions = false;
  bool _closed = false;
  bool _auto = true;

  late MvState _state;
  Map<String, Object?> _selections = <String, Object?>{};
  Map<String, int> _offsets = <String, int>{};
  String _key = '';
  String _mvId = '';
  String _requestedMvId = '';
  int _generation = 0;
  int _sourceGeneration = 0;
  int _epoch = 0;
  double _audioPosition = -1;
  bool _audioPlaying = false;
  late DateTime _audioClock;
  double _videoPositionMs = 0;

  /// 当前快照。
  MvState get state => _state;

  /// 当前版本列表。
  List<ProviderMvVersion> get versions => _state.versions;

  /// 当前来源是否支持 MV（Qt `supported`）。
  bool get supported => _supported;

  /// 是否自动查找（Qt `m_enabled`）。
  bool get auto => _auto;

  /// 是否已被 [close]（宿主据此跳过 tick）。
  bool get closed => _closed;

  /// 当前选中的版本 id。
  String get selectedVersionId => _state.selectedVersionId;

  /// 画面偏移（毫秒）：Qt `offset()` 的 `clamp(m_offsets[m_mvID], -60000, 60000)`。
  int get offset => math.max(-60000, math.min(60000, _offsets[_mvId] ?? 0));

  /// 视频位置记账值（无渲染器时它只反映"上次对齐到的目标"）。
  double get videoPositionMs => _videoPositionMs;

  /// 选中的版本下标（Qt `versionIndex()`：选择表 → requestedMvID/m_mvID → -1）。
  int get versionIndex {
    final Object? stored = _selections[_key];
    final String id = stored is String && stored.isNotEmpty
        ? stored
        : (_requestedMvId.isNotEmpty ? _requestedMvId : _mvId);
    if (id.isEmpty) {
      return -1;
    }
    for (int index = 0; index < _state.versions.length; index++) {
      if (_state.versions[index].id == id) {
        return index;
      }
    }
    return -1;
  }

  /// 绑定网关与平台能力（Qt 构造里拿到的 descriptor 事实 + resolve 回调）。
  Future<void> attach(
    ProviderGateway gateway, {
    required bool providerSupportsMv,
    required bool providerSupportsMvVersions,
  }) async {
    _gateway = gateway;
    _supported = providerSupportsMv;
    _supportsVersions = providerSupportsMvVersions;
    _closed = false;
  }

  /// 数据源重建（Qt `Host::invalidated` → `m_epoch != m_host->epoch → refresh(true)`）。
  void invalidate() {
    _epoch++;
    _generation++;
  }

  /// 地址校验：合法返回 true（Qt/src/MvController.cpp:655-658）。
  bool validUrl(String url) => MvTrackValidator.validateUrl(url) == null;

  /// 找片 → 解析地址 → 拉版本列表。
  ///
  /// [trackId] 为 null 表示沿用上次曲目（宿主 tick 的常规调用）；空串表示"没有播放曲目"。
  Future<void> refresh({String? trackId, bool force = false}) async {
    final String track = trackId ?? _state.trackId;
    final ProviderGateway? gateway = _gateway;
    final String key = '${gateway?.providerId ?? ''}:$track';

    // Qt/src/MvController.cpp:563-566：键相同且 epoch 未变时只 sync，不再请求。
    if (!force && key == _key && _epoch == _epochSnapshot && _state.trackId == track) {
      _syncAudioClock();
      return;
    }

    final int generation = ++_generation;
    final int epoch = _epochSnapshot = _epoch;
    if (key != _key) {
      // Qt :570-573：换了曲目/来源才清空版本列表。
      _state = MvState(auto: _auto, offsets: Map<String, int>.of(_offsets));
    }
    _key = key;
    _mvId = '';
    _requestedMvId = '';
    _videoPositionMs = 0;
    _audioPosition = -1;
    _audioPlaying = false;
    _audioClock = _clock();

    final Object? stored = _selections[key];
    final String selected = stored is String ? stored : '';

    // Qt :585-592 的三元状态串：空曲目 → 正在查找 → 不支持。
    _emit(MvState(
      trackId: track,
      phase: track.isEmpty
          ? MvPhase.idle
          : (_supported ? MvPhase.searching : MvPhase.unsupported),
      status: track.isEmpty ? mvIdleStatus : (_supported ? '正在查找关联 MV…' : mvUnsupportedStatus),
      selectedVersionId: selected,
      auto: _auto,
      offsets: Map<String, int>.of(_offsets),
    ));

    // Qt :595-598：不自动查找 / 空曲目 / 不支持，到此为止。
    if (!_auto || track.isEmpty || !_supported || gateway == null) {
      return;
    }

    _emit(_state.copyWith(phase: MvPhase.searching, status: '正在查找歌曲关联 MV…'));

    // Qt :600-604：请求带上次选择；本类的网关契约收窄为 versionId（见文件头）。
    final Future<void> video =
        _resolveVideo(track, selected, generation: generation, epoch: epoch);
    final Future<void> list = _supportsVersions
        ? _resolveVersions(track, generation: generation, epoch: epoch)
        : Future<void>.value();
    await Future.wait<void>(<Future<void>>[video, list]);
  }

  /// 上一次 refresh 的 epoch 快照（:563 的短路比较用）。
  int _epochSnapshot = 0;

  Future<void> _resolveVideo(
    String track,
    String requestedId, {
    required int generation,
    required int epoch,
  }) async {
    final ProviderGateway? gateway = _gateway;
    if (gateway == null) {
      return;
    }
    final int sourceGeneration = ++_sourceGeneration;
    _requestedMvId = requestedId;
    _emit(_state.copyWith(phase: MvPhase.searching, status: '正在加载视频版本…'));

    ProviderMvTrack? resolved;
    String failure = '';
    try {
      resolved = await gateway.mv(
        // 没有选中版本时回落曲目 id（平台侧把它当"默认版本"）。
        versionId: requestedId.isNotEmpty ? requestedId : track,
      );
    } catch (error) {
      failure = error is ProviderUnavailableError ? error.message : '$error';
    }
    // Qt :641-643 的迟到回调闸门：generation / sourceGeneration / epoch 同时一致才落地。
    if (_generation != generation || _sourceGeneration != sourceGeneration || _epoch != epoch) {
      return;
    }
    if (failure.isNotEmpty) {
      _fail('MV 加载失败：$failure');
      return;
    }
    final ProviderMvTrack? mv = resolved;
    if (mv == null || (mv.id.isEmpty && mv.url.isEmpty)) {
      // Qt :654-655：值非 object（本侧约定：id 与 url 都为空）→ 没有关联 MV 但有版本可选。
      _emit(_state.withTrack(null).copyWith(
            phase: MvPhase.versions,
            status: '此歌曲没有关联 MV，可手动选择视频版本',
          ));
      return;
    }
    final String? invalid = MvTrackValidator.validateUrl(mv.url);
    if (invalid != null) {
      // Qt :655-660：非法地址当场返回，不改 m_mvID、不建播放源。
      _fail(invalid);
      return;
    }

    _mvId = mv.id;
    _videoPositionMs = _videoPosition(_audioPositionNow(), 0);
    _emit(MvState(
      trackId: _state.trackId,
      phase: MvPhase.playing,
      status: '静音跟随音乐 · ${mv.resolution}p',
      track: mv,
      versions: _state.versions,
      selectedVersionId: _state.selectedVersionId,
      auto: _auto,
      offsets: Map<String, int>.of(_offsets),
      resolution: mv.resolution,
      versionStatus: _state.versionStatus,
    ));
  }

  Future<void> _resolveVersions(
    String track, {
    required int generation,
    required int epoch,
  }) async {
    final ProviderGateway? gateway = _gateway;
    if (gateway == null) {
      return;
    }
    // Qt :607：版本列表在路上时先给附注串。
    _emit(_state.copyWith(versionStatus: '正在查找视频版本…'));

    List<ProviderMvVersion>? loaded;
    try {
      loaded = await gateway.mvVersions(trackId: track);
    } catch (_) {
      loaded = null;
    }
    if (_generation != generation || _epoch != epoch) {
      return;
    }
    if (loaded == null) {
      // Qt :625-627：列表失败只改附注，不动主状态串。
      _emit(_state.copyWith(versionStatus: '视频版本加载失败，可重试'));
      return;
    }

    List<ProviderMvVersion> list = List<ProviderMvVersion>.of(loaded);
    // Qt :616-618：已选 id 不在新列表里时补一条"已选版本 · <id>"到表头。
    final Object? stored = _selections[_key];
    final String selected = stored is String ? stored : '';
    final String fallback = selected.isNotEmpty ? selected : _mvId;
    if (fallback.isNotEmpty && !_contains(list, fallback)) {
      list = <ProviderMvVersion>[
        ProviderMvVersion(id: fallback, title: '已选版本 · $fallback'),
        ...list,
      ];
    }
    // 网关契约只回列表、没有 Qt 的 `warning` 字段，所以附注统一清空。
    _emit(_state.copyWith(
      versions: list,
      versionStatus: '',
      selectedVersionId: _contains(list, fallback) ? fallback : '',
    ));
    if (selected.isEmpty && list.isNotEmpty && !list.first.associated) {
      // Qt :619-623：没选过、首项又不是"歌曲关联" → 直接用首项重解析。
      await _resolveVideo(track, list.first.id, generation: generation, epoch: epoch);
    }
    if (_state.versions.isEmpty) {
      _emit(_state.copyWith(versionStatus: '未找到其他视频版本'));
    }
  }

  static bool _contains(List<ProviderMvVersion> list, String id) {
    for (final ProviderMvVersion version in list) {
      if (version.id == id) {
        return true;
      }
    }
    return false;
  }

  void _fail(String status) {
    _emit(_state.withTrack(null).copyWith(phase: MvPhase.failed, status: status));
  }

  /// 选择版本（Qt/src/MvController.cpp:474-495）：落偏好并重新解析。
  Future<void> selectVersion(String versionId) async {
    final int index = _state.versions.indexWhere(
      (ProviderMvVersion version) => version.id == versionId,
    );
    if (index < 0) {
      return;
    }
    final String id = _state.versions[index].id;
    final bool same = index == versionIndex;
    if (same && _selections[_key] == id) {
      return;
    }
    _selections[_key] = id;
    while (_selections.length > mvSelectionCap) {
      final String oldest = _selections.keys.firstWhere((String key) => key != _key);
      _selections.remove(oldest);
    }
    _preferences.write(mvVersionsPreferenceKey, jsonEncode(_selections));
    _emit(_state.copyWith(selectedVersionId: id));
    if (!same) {
      await refresh(force: true);
    }
  }

  /// 开关自动查找（Qt `setEnabled`，:182-199）：写 `mv-auto` 后重新查找。
  Future<void> setAuto(bool value) async {
    if (_auto == value) {
      return;
    }
    _auto = value;
    _preferences.write(mvAutoPreferenceKey, value ? 'on' : 'off');
    _emit(_state.copyWith(auto: _auto));
    await refresh(force: true);
  }

  /// 重试（Qt `retry()` == `refresh(true)`，:553-556）。
  Future<void> reload() => refresh(force: true);

  /// 关闭面板（Qt `hideForQuit` 的移动端等价物：停表、清源、回 idle）。
  void close() {
    _closed = true;
    _generation++;
    _sourceGeneration++;
    _gateway = null;
    _supported = false;
    _supportsVersions = false;
    _mvId = '';
    _requestedMvId = '';
    _key = '';
    _videoPositionMs = 0;
    _audioPosition = -1;
    _audioPlaying = false;
    _emit(MvState(status: mvIdleStatus, auto: _auto, offsets: Map<String, int>.of(_offsets)));
  }

  /// 调整画面偏移（Qt `adjustOffset`：参数先 clamp ±1000，再叠加到当前偏移）。
  void adjustOffset(int milliseconds) {
    _saveOffset(offset + math.max(-1000, math.min(1000, milliseconds)));
  }

  /// 归零偏移（Qt `resetOffset`）。
  void resetOffset() => _saveOffset(0);

  void _saveOffset(int value) {
    if (_mvId.isEmpty) {
      return;
    }
    _offsets[_mvId] = math.max(-60000, math.min(60000, value));
    while (_offsets.length > mvOffsetCap) {
      final String oldest = _offsets.keys.firstWhere((String key) => key != _mvId);
      _offsets.remove(oldest);
    }
    _preferences.write(mvOffsetsPreferenceKey, jsonEncode(_offsets));
    _emit(_state.copyWith(offsets: Map<String, int>.of(_offsets)));
  }

  /// 对齐视频到音乐位置；返回是否该 seek（Qt/src/MvController.cpp:691 的严格大于）。
  ///
  /// 音乐位置用与 Qt 相同的记账（:673-676）：位置或播放态变化时重启单调时钟，
  /// 之后按 `_audioPosition + 时钟流逝` 推算。
  bool syncToMusic(double musicPositionMs, {required bool playing}) {
    final double position = musicPositionMs.isFinite ? musicPositionMs : 0;
    if (position != _audioPosition || playing != _audioPlaying) {
      _audioPosition = position;
      _audioPlaying = playing;
      _audioClock = _clock();
    }
    if (_closed || _mvId.isEmpty || _state.track == null) {
      return false;
    }
    final double target = _videoPosition(_audioPositionNow(), offset);
    if (!MvTrackValidator.shouldSeek(_videoPositionMs, target, playing: playing)) {
      return false;
    }
    _videoPositionMs = target;
    return true;
  }

  /// 视频目标位置（Qt `MvController::videoPosition`，:504-511）：`max(0, audio+offset)`。
  double videoPosition(double audioMs, int offsetMs) => _videoPosition(audioMs, offsetMs);

  double _videoPosition(double audioMs, int offsetMs) {
    final double position = audioMs.isFinite ? math.max(0, audioMs + offsetMs) : 0;
    return math.min(position, 1e12);
  }

  double _audioPositionNow() =>
      _audioPosition +
      (_audioPlaying ? _clock().difference(_audioClock).inMilliseconds.toDouble() : 0);

  /// Qt 在空曲目/冷却期只让时钟保持有效，不推位置。
  void _syncAudioClock() {
    if (_audioPosition < 0) {
      _audioPosition = 0;
      _audioPlaying = false;
      _audioClock = _clock();
    }
  }

  void _emit(MvState next) {
    _state = next;
    _onChanged?.call(next); // 宿主据此重绘；域层本身不监听。
  }

  static Map<String, Object?> _decodeMap(String raw) {
    if (raw.isEmpty) {
      return <String, Object?>{};
    }
    try {
      final Object? decoded = jsonDecode(raw);
      if (decoded is Map) {
        return decoded.map<String, Object?>((Object? key, Object? value) =>
            MapEntry<String, Object?>(key.toString(), value));
      }
    } on FormatException {
      // 坏偏好与 Qt 一样静默丢掉（QJsonDocument::fromJson 失败给空对象）。
      return <String, Object?>{};
    }
    return <String, Object?>{};
  }

  static Map<String, int> _decodeOffsetMap(String raw) {
    final Map<String, int> result = <String, int>{};
    for (final MapEntry<String, Object?> entry in _decodeMap(raw).entries) {
      final Object? value = entry.value;
      final int? parsed = value is num
          ? value.toInt()
          : (value is String ? int.tryParse(value) : null);
      if (parsed != null) {
        result[entry.key] = math.max(-60000, math.min(60000, parsed));
      }
    }
    return result;
  }
}

/// MV 面板的动作串（**本文件是唯一作者**）。
///
/// Qt 侧没有这套动作：`Qt/src/NativeHudController.cpp:358-359` 只在
/// `PlatformFeatures::MusicVideo` 为真时转发 `mv`，而 `Qt/src/PlatformFeatures.h:23-27`
/// 的 `MusicVideo = !RHINE_MOBILE && (WIN|LINUX|MACOS)` 在 Android 上恒 false。
/// 因此这里按 `MvController` 的公开槽位（retry / setVersionIndex / adjustOffset /
/// resetOffset / setEnabled / 打开窗口）逐一命名，宿主按 `mv:` 前缀分发：
///
/// - `mv:open`                 打开 MV 面板（方向决定竖屏页 / 横屏弹层）
/// - `mv:close`                关闭面板（= [MvController.close]；弹层框架另有 close-modal）
/// - `mv:retry`                重新查找（= `refresh(force: true)`）
/// - `mv:versions`             只刷新版本列表
/// - `mv:auto:on` / `mv:auto:off`  开关自动查找（写 `mv-auto`）
/// - `mv:version:<id>`         选择版本（= `selectVersion(id)`）
/// - `mv:offset:<ms>`          绝对偏移（clamp ±60000），`mv:offset:+500` / `mv:offset:-500`
/// - `mv:offset:reset`         归零
abstract final class MvAction {
  /// 打开 MV 面板。
  static const String open = 'mv:open';

  /// 关闭 MV 面板。
  static const String close = 'mv:close';

  /// 重新查找（Qt `retry()`）。
  static const String retry = 'mv:retry';

  /// 只刷新版本列表。
  static const String versions = 'mv:versions';

  /// 打开自动查找（写 `mv-auto=on`）。
  static const String autoOn = 'mv:auto:on';

  /// 关闭自动查找（写 `mv-auto=off`）。
  static const String autoOff = 'mv:auto:off';

  /// 偏移归零（Qt `resetOffset()`）。
  static const String offsetReset = 'mv:offset:reset';

  /// 版本选择的命中前缀。
  static const String versionPrefix = 'mv:version:';

  /// 选择某个版本的动作串。
  static String version(String id) => '$versionPrefix$id';

  /// 偏移的动作前缀（后面接带符号毫秒数）。
  static const String offsetPrefix = 'mv:offset:';

  /// 绝对偏移动作串。
  static String offset(int milliseconds) => '$offsetPrefix$milliseconds';
}
