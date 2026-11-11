/// Qt 移植源：Qt/src/MusicPlayer.h、Qt/src/MusicPlayer.cpp
///
/// 播放传输状态机（DEDUP-04 播放器侧）。只移植可静态判定的传输状态与队列推进：
/// 入队/播放的队列插入与 current 选择、tick 时间推进、播放与暂停切换、seek(fraction)、
/// next(direction, ended)、remove/clearUpcoming/stop、mode 取值、history 与
/// sessionState/restoreSessionState 的纯数据子集。
///
/// 出域（不在本文件）：音源获取与解码（MusicPlayer::prepare :301-443）、音质
/// （:181-185、:427、:430-437）、封面（:199-222、:283-285、:616）、歌词（:492、:611）、
/// 后台播放服务桥接（:163-179、:472-474、:628-641、:686-746）、偏好存储实现
/// （:188、:421-422、:667 的具体落盘）。这些能力一律通过注入端口留在域外：
/// 见 MediaHostPort / PreferencePort / PlaybackEnginePort。本文件是纯 Dart，
/// 不 import flutter，也不 import lib/data。
///
/// 远程播放服务假设：Host::playbackConnection() 恒为不存在（Qt 仅在该服务存在时才走
/// remoteCommand/applyPlaybackSnapshot 分支，:163-179、:261-263、:472-474）。因此
/// tick 的早退（:472-474）与 restore 的 hydrate=!playbackConnection（:770、:778）都取本地分支；
/// 该假设与出域项一并记入报告的 RESIDUAL_RISK。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'playback_queue.dart';

/// 平台媒体宿主端口，对齐 Qt Host 中与播放传输相关的入口（Qt/src/Host.h:44-49）。
abstract class MediaHostPort {
  /// Host::mediaControl(action, value)（Qt/src/Host.h:48；Qt 的 value 默认 0）。
  void mediaControl(String action, [double value = 0]);

  /// Host::mediaState()（Qt/src/Host.h:49）的 QVariantMap 等价物；键集见
  /// Qt/src/AudioPlayer.cpp:430-443：playing/position/duration/seekable/volume/ended/
  /// error/recoverable/requested/buffering。这些值的 QVariant 实际类型是
  /// bool / qlonglong / double / QString，本文件按该类型集解析。
  Map<String, Object?> mediaState();

  /// Host::mediaMetadata(title, artist, album, cover)（Qt/src/Host.h:44）；
  /// stop 以四个空串清空（MusicPlayer.cpp:620）。
  void mediaMetadata(String title, String artist, String album, String cover);
}

/// 偏好端口，对齐 Qt Host::preference / Host::setPreference。
/// 播放侧只读写 play-history（Qt/src/MusicPlayer.cpp:188、:421-422、:667）。
abstract class PreferencePort {
  String read(String key);

  void write(String key, String value);
}

/// 音源准备端口：Qt MusicPlayer::prepare（:301-443）中依赖 API、解码、封面与歌词的部分。
///
/// 实现方完成取地址与加载后，必须回调 MusicPlayer.playbackStarted 或
/// MusicPlayer.fail，并把 prepare 收到的 generation 原样传回（Qt 用 valid(generation)
/// 绑定迟到回调，:442；成功回调里的播放器侧收尾是 :408-440）。
abstract class PlaybackEnginePort {
  void prepare(Map<String, Object?> track, int generation, {bool reload = false});
}

/// Qt QJsonValue::toString(default)：非字符串取默认值（:774 的 provider 缺省即此语义）。
String _text(Object? value, [String fallback = '']) => value is String ? value : fallback;

/// Qt QJsonValue::toObject()：非对象得到空对象（:767）。
Map<String, Object?> _object(Object? value) {
  if (value is Map) {
    return value.map<String, Object?>((key, item) => MapEntry<String, Object?>(key.toString(), item));
  }
  return <String, Object?>{};
}

/// Qt QJsonValue::toArray()：非数组得到空数组（:768）。
List<Object?> _array(Object? value) => value is List ? value : const <Object?>[];

/// Qt QJsonValue::toDouble(default)：只有 JSON 数值可转换（:761、:276、:485、:553）。
double _number(Object? value, [double fallback = 0]) => value is num ? value.toDouble() : fallback;

/// Qt QJsonValue::toBool()：只有 JSON 布尔为真（:277、:484、:534、:556、:779）。
bool _flag(Object? value) => value is bool && value;

/// Qt QJsonValue::toInteger()：整数之外的取值一律返回默认 0（:495-496 的 ended 序列）。
int _integer(Object? value) {
  if (value is int) {
    return value;
  }
  if (value is double) {
    if (!value.isFinite) {
      return 0;
    }
    final truncated = value.toInt();
    return truncated.toDouble() == value ? truncated : 0;
  }
  return 0;
}

/// Qt QJsonValue::toInt(default)（Qt 6 qjsonvalue.cpp:686-705，与
/// lib/data/storage/playback_store.dart:76-109 的同名实现逐条一致）：
/// 整数只在 int32 区间内转换；浮点只接受 32 位区间内的整数值；其余取默认值。
int _int32(Object? value, int fallback) {
  const int intMin = -2147483648;
  const int supremum = 2147483648;
  const double intMinDouble = -2147483648.0;
  const double supremumDouble = 2147483648.0;
  if (value is int) {
    return value >= intMin && value < supremum ? value : fallback;
  }
  if (value is double) {
    if (!value.isFinite || value < intMinDouble || value >= supremumDouble) {
      return fallback;
    }
    final truncated = value.toInt();
    return truncated.toDouble() == value ? truncated : fallback;
  }
  return fallback;
}

/// Qt QVariant::toDouble()：数值原样、布尔取 1/0、其余 0。
/// 只在 Host::mediaState 的返回值上使用（:752、:755），其生产者类型见
/// Qt/src/AudioPlayer.cpp:430-443（bool/qlonglong/double/QString）；QString 的数值解析
/// 不在生产者输出中，故不建模。
double _variantDouble(Object? value) {
  if (value is bool) {
    return value ? 1 : 0;
  }
  if (value is num) {
    return value.toDouble();
  }
  return 0;
}

/// Qt QVariant::toBool()：布尔原样、数值非零为真、其余 false（:755）。
bool _variantBool(Object? value) {
  if (value is bool) {
    return value;
  }
  if (value is num) {
    return value != 0;
  }
  return false;
}

/// Qt QVariant::toLongLong()：整数原样、浮点向零截断、其余 0（:409）。
int _variantLongLong(Object? value) {
  if (value is int) {
    return value;
  }
  if (value is double) {
    return value.isFinite ? value.truncate() : 0;
  }
  return 0;
}

/// std::clamp 的比较顺序（先 lo 后 hi）；NaN 原样返回，与 Qt :485、:553、:557 一致。
double _clamp(double value, double lo, double hi) {
  if (value < lo) {
    return lo;
  }
  if (hi < value) {
    return hi;
  }
  return value;
}

/// QJsonObject::operator== 的深比较（键序无关，:515 的 state != previous）。
bool _jsonEquals(Object? left, Object? right) {
  if (left is Map && right is Map) {
    if (left.length != right.length) {
      return false;
    }
    for (final key in left.keys) {
      if (!right.containsKey(key) || !_jsonEquals(left[key], right[key])) {
        return false;
      }
    }
    return true;
  }
  if (left is List && right is List) {
    if (left.length != right.length) {
      return false;
    }
    for (var row = 0; row < left.length; row++) {
      if (!_jsonEquals(left[row], right[row])) {
        return false;
      }
    }
    return true;
  }
  return left == right;
}

/// QJsonValue 赋值时的数值归一：QJsonObject 内部一律按双精度保存（:480-483 的合并）。
Object? _jsonValue(Object? value) => value is num ? value.toDouble() : value;

/// 播放传输状态机：Qt/src/MusicPlayer.h:9-77 的纯数据子集。
class MusicPlayer {
  /// 构造对应 Qt MusicPlayer::MusicPlayer（:159-223）：state 初值（:161）、
  /// queue.changed 直连 changed（:162）、play-history 历史回填（:188-198）。
  /// 远程服务分支（:163-179）与音质/封面偏好（:181-187）不建模。
  MusicPlayer({
    required MediaHostPort media,
    required PreferencePort preferences,
    required PlaybackEnginePort engine,
    QueueMetadataPort? queueApi,
    String Function()? provider,
    math.Random? random,
  })  : _media = media,
        _preferences = preferences,
        _engine = engine,
        _provider = provider ?? _defaultProvider,
        queue = PlaybackQueue(queueApi, random: random) {
    queue.addListener(_emit);
    _seedHistory(_preferences.read('play-history'));
  }

  static String _defaultProvider() => 'netease';

  /// Qt public 字段 queue（MusicPlayer.h:40），构造时注入同一 MusicApi（:160）。
  final PlaybackQueue queue;

  final MediaHostPort _media;
  final PreferencePort _preferences;
  final PlaybackEnginePort _engine;

  /// Qt m_api->provider，经端口注入；缺省 netease 与 PlaybackQueue 的缺省一致。
  final String Function() _provider;

  /// Qt public 字段 state（MusicPlayer.h:43），初值逐键对齐 :161。
  /// Qt 侧是可变 QJsonObject，但写入点只有本类（:480-483、:621-623）；对外只暴露快照。
  final Map<String, Object?> _state = <String, Object?>{
    'playing': false,
    'position': 0.0,
    'duration': 0.0,
    'volume': 0.7,
    'seekable': false,
  };

  /// Qt public 字段 history（MusicPlayer.h:41）；条目是完整曲目对象。
  List<Map<String, Object?>> _history = <Map<String, Object?>>[];

  /// Qt public 字段 current（MusicPlayer.h:42）；空对象表示无当前曲目。
  Map<String, Object?> _current = <String, Object?>{};

  bool _loading = false;
  bool _failed = false;
  bool _trial = false;
  bool _previewRequested = false;
  String _status = '';

  /// Qt public 字段 mode，初值 "all"（MusicPlayer.h:48）。
  String _mode = 'all';

  /// Qt m_generation（:62）。
  int _generation = 0;

  /// Qt m_endSerial（:63）。
  int _endSerial = 0;

  /// Qt m_lastPoll（:64），初值 -1。
  double _lastPoll = -1;

  /// Qt m_resumePosition（:65）：装配即代表「待恢复位置」，0 也是装配。
  double? _resumePosition;

  /// Qt m_resumePaused（:66）。
  bool _resumePaused = false;

  /// Qt m_restoringSession（:67）：Qt 只在 :278 置真、从不复位，此处保留同一粘滞语义。
  bool _restoringSession = false;

  /// Qt m_recoveryAttempts（:68）。
  int _recoveryAttempts = 0;

  /// Qt onEnd 钩子（MusicPlayer.h:53）：存在时结束事件交给它，否则自动下一首（:498-502）。
  void Function()? onEnd;

  final List<void Function()> _listeners = <void Function()>[];

  /// 订阅 changed（MusicPlayer.h:56）。
  void addListener(void Function() listener) => _listeners.add(listener);

  void removeListener(void Function() listener) => _listeners.remove(listener);

  void _emit() {
    for (final listener in List<void Function()>.of(_listeners)) {
      listener();
    }
  }

  Map<String, Object?> get current => Map<String, Object?>.of(_current);

  List<Map<String, Object?>> get history =>
      [for (final track in _history) Map<String, Object?>.of(track)];

  Map<String, Object?> get state => Map<String, Object?>.of(_state);

  bool get loading => _loading;

  bool get failed => _failed;

  bool get trial => _trial;

  bool get previewRequested => _previewRequested;

  String get status => _status;

  String get mode => _mode;

  static final RegExp _trackIdPattern = RegExp(r'^[a-zA-Z0-9_-]{1,80}$');

  /// :188-198：偏好 play-history 的 JSON 数组回填历史；只收 kind 为 song 且 id 匹配
  /// ^[a-zA-Z0-9_-]{1,80}$ 的条目，追加时即计数，满 200 条停止（:194-196）。
  /// 解析失败与「不是数组」都等价于空数组（QJsonDocument::fromJson(...).array()）。
  void _seedHistory(String raw) {
    if (raw.isEmpty) {
      return;
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } catch (_) {
      return;
    }
    if (decoded is! List) {
      return;
    }
    for (final value in decoded) {
      final track = _object(value);
      if (track['kind'] == 'song' && _trackIdPattern.hasMatch(_text(track['id']))) {
        _history.add(track);
        if (_history.length == 200) {
          break;
        }
      }
    }
  }

  /// :229-246。去除非当前项中的同曲目，再插到队尾或当前项之后；不切歌、不改变暂停意图（:229）。
  /// 远程分支（:231-241）不建模，本地分支的 kind 守卫在 :242-244。
  bool enqueue(Map<String, Object?> track, {bool next = false}) {
    if (track['kind'] != 'song') {
      return false;
    }
    return queue.enqueue(track, next: next);
  }

  /// :248-292。先停旧音源并推进代数，再交给音源端口准备；迟到的地址不能恢复旧曲目（:248）。
  ///
  /// 参数与 Qt 的 std::optional 逐项对应：source 非空即替换队列（:268-270），
  /// queueIndex 非空即按行选中——装配的 optional 即使值为 0 也会执行（:272-274），
  /// resume 非空即进入「恢复会话」语义（:276-278）。
  void play(
    Map<String, Object?> track, {
    List<Map<String, Object?>>? source,
    int? queueIndex,
    bool preview = false,
    Map<String, Object?>? resume,
  }) {
    final provider = _provider();
    if (track['kind'] != 'song' ||
        (provider == 'local') != (_text(track['provider']) == 'local')) {
      return;
    }
    if (source != null) {
      queue.replace(source);
    }
    queue.selectTrack(track);
    if (queueIndex != null) {
      queue.select(queueIndex);
    }
    final generation = ++_generation;
    _resumePosition = resume == null ? null : _number(resume['position']);
    _resumePaused = resume != null && !_flag(resume['requested']);
    _restoringSession = resume != null;
    _recoveryAttempts = 0;
    _previewRequested = preview && provider == 'qq';
    _media.mediaControl('stop');
    _current = Map<String, Object?>.of(track);
    _loading = true;
    _failed = false;
    _trial = false;
    _status = '正在准备：' + _text(track['title']);
    _emit();
    _engine.prepare(_current, generation);
  }

  /// :294-299。远程分支（:295-297）不建模；queue.load 是异步补全，Qt 不在本层等待。
  void loadQueue(List<String> ids, List<Map<String, Object?>> known) {
    unawaited(queue.load(ids, known));
  }

  /// :471-518。按 0.1 秒节流合并 Host::mediaState，推进恢复定位、结束事件与错误处理。
  /// 远程分支的早退（:472-474）不建模（本移植无后台播放服务）。
  void tick(double time, {bool force = false}) {
    if (!force && time - _lastPoll < 0.1) {
      return;
    }
    _lastPoll = time;
    final previous = Map<String, Object?>.of(_state);
    for (final entry in _media.mediaState().entries) {
      _state[entry.key] = _jsonValue(entry.value);
    }
    if (_resumePosition != null && !_loading && _flag(_state['seekable'])) {
      final position = _clamp(_resumePosition!, 0, _number(_state['duration']));
      _resumePosition = null;
      _media.mediaControl('seek', position);
      if (_resumePaused) {
        _media.mediaControl('pause');
      }
    }
    if (_current.isNotEmpty &&
        !_loading &&
        _state.containsKey('ended') &&
        _integer(_state['ended']) != _endSerial) {
      _endSerial = _integer(_state['ended']);
      final end = onEnd;
      if (end != null) {
        end();
      } else {
        next(1, true);
      }
      return;
    }
    final playbackError = _text(_state['error']);
    if (!_loading &&
        _current.isNotEmpty &&
        playbackError.isNotEmpty &&
        (!_failed || _status != playbackError)) {
      const int maxRecoveryAttempts = 2;
      if (!_failed &&
          _flag(_state['recoverable']) &&
          _recoveryAttempts < maxRecoveryAttempts &&
          _text(_current['provider']) != 'local') {
        _recoverPlayback();
        return;
      }
      fail(playbackError);
    } else if (!_jsonEquals(_state, previous)) {
      _emit();
    }
  }

  /// :520-536。失败且仍有当前曲目时按键作恢复式重播；待恢复定位装配时只翻转暂停意图；
  /// 其余情况把当前 playing 取反交给 setPaused。
  void toggle() {
    if (_failed && _current.isNotEmpty) {
      final resume = _resumePosition == null ? null : sessionState();
      play(_current, queueIndex: queue.index, preview: _previewRequested, resume: resume);
      return;
    }
    if (_resumePosition != null) {
      setPaused(!_resumePaused);
      return;
    }
    if (!_loading && _current.isNotEmpty) {
      setPaused(_flag(_state['playing']));
    }
  }

  /// :538-546。待恢复定位装配时只记录意图；媒体控制始终下发。Qt 此路径不发 changed。
  void setPaused(bool paused) {
    if (_resumePosition != null) {
      _resumePaused = paused;
    }
    _media.mediaControl(paused ? 'pause' : 'resume');
  }

  /// :548-559。待恢复定位装配时把比例折算成待恢复位置；否则在可定位时下发秒数。
  void seek(double fraction) {
    if (_resumePosition != null) {
      _resumePosition = _clamp(fraction, 0, 1) * _number(_state['duration']);
      return;
    }
    if (_flag(_state['seekable'])) {
      _media.mediaControl('seek', _clamp(fraction, 0, 1) * _number(_state['duration']));
    }
  }

  /// :573-587。ended 只在远程分支使用（:574-575），本地分支只按 direction 推进。
  void next([int direction = 1, bool ended = false]) {
    if (queue.isEmpty) {
      return;
    }
    final selected = queue.navigate(direction, _mode);
    if (selected < 0) {
      _status = '队列已播放完';
      _emit();
      return;
    }
    play(queue.at(selected), queueIndex: selected);
  }

  /// :589-594。当前项不可移除由 PlaybackQueue::remove 自己拒绝。
  void remove(int index) {
    queue.remove(index);
  }

  /// :596-601。只保留当前项。
  void clearUpcoming() {
    queue.clearUpcoming(_current);
  }

  /// :603-625。停止播放并作废当前代数；音量与历史等可恢复偏好保持不变（:603）。
  /// 只重置 playing/position/duration 三个键，volume 与 seekable 保留（:621-623）。
  void stop() {
    ++_generation;
    _resumePosition = null;
    _recoveryAttempts = 0;
    _loading = false;
    _failed = false;
    _status = '';
    _current = <String, Object?>{};
    queue.clear();
    _media.mediaControl('stop');
    _media.mediaMetadata('', '', '', '');
    _state['playing'] = false;
    _state['position'] = 0.0;
    _state['duration'] = 0.0;
    _emit();
  }

  /// :643-651。白名单外取值被忽略且不发 changed（:647-650）。
  void setMode(String value) {
    if (_modes.contains(value)) {
      _mode = value;
      _emit();
    }
  }

  /// :662-669。清空历史并写回 "[]"。
  void clearHistory() {
    _history = <Map<String, Object?>>[];
    _preferences.write('play-history', '[]');
    _emit();
  }

  static const Set<String> _modes = <String>{'off', 'all', 'one', 'shuffle'};

  /// :749-758。键与取值逐项对齐：current/queue/index/mode/position/requested/preview。
  /// position 优先取待恢复位置，否则取 Host::mediaState 的 position（缺失回落 state，:752）；
  /// requested 在待恢复时取 !m_resumePaused，否则 loading 或 live requested/playing（:753-755）。
  Map<String, Object?> sessionState() {
    final live = _media.mediaState();
    final positionFallback = _state.containsKey('position') ? _state['position'] : 0;
    final position = _resumePosition ??
        _variantDouble(live.containsKey('position') ? live['position'] : positionFallback);
    final requested = _resumePosition != null
        ? !_resumePaused
        : _loading ||
            _variantBool(live.containsKey('requested') ? live['requested'] : _state['playing']);
    return <String, Object?>{
      'current': Map<String, Object?>.of(_current),
      'queue': queue.toJson(),
      'index': queue.index,
      'mode': _mode,
      'position': position,
      'requested': requested,
      'preview': _previewRequested,
    };
  }

  /// :760-780。门禁顺序逐行对齐 QJson 语义：先 position 闸门（:761-764，越界则整个恢复放弃），
  /// 再无条件定 mode（:765-766，先于 current 判定），再分别处理空 current（:769-773）
  /// 与 kind/provider 守卫（:774-776）；队列先恢复再选曲（:777-779）。
  void restoreSessionState(Map<String, Object?> saved) {
    final position = _number(saved['position'], -1);
    if (!position.isFinite || position < 0 || position > 1e12) {
      return;
    }
    final savedMode = _text(saved['mode']);
    _mode = _modes.contains(savedMode) ? savedMode : 'all';
    final track = _object(saved['current']);
    final savedQueue = _array(saved['queue']);
    if (track.isEmpty) {
      queue.restore(_tracks(savedQueue), _int32(saved['index'], -1), true);
      _emit();
      return;
    }
    final provider = _provider();
    if (track['kind'] != 'song' || _text(track['provider'], provider) != provider) {
      return;
    }
    queue.restore(_tracks(savedQueue), _int32(saved['index'], -1), true);
    play(track, preview: _flag(saved['preview']), resume: saved);
  }

  static List<Map<String, Object?>> _tracks(List<Object?> values) =>
      [for (final value in values) _object(value)];

  /// :408-440：音源就绪后属于播放器状态机的收尾（prepare 成功回调在端口实现内）。
  /// generation 非空时按 Qt 的 valid(generation) 拦迟到回调（:442）。
  /// 音质后缀（:427、:430-437）、封面与歌词不在本域，故状态文本只到 :428-429。
  void playbackStarted({int? generation, bool trial = false}) {
    if (generation != null && generation != _generation) {
      return;
    }
    _resumePosition = null;
    _endSerial = _variantLongLong(_media.mediaState()['ended']);
    final entry = Map<String, Object?>.of(_current);
    entry['wiki'] = '';
    entry['description'] = '';
    final recent = <Map<String, Object?>>[entry];
    for (final value in _history) {
      if (PlaybackQueue.identity(value) != PlaybackQueue.identity(_current) &&
          recent.length < 200) {
        recent.add(Map<String, Object?>.of(value));
      }
    }
    _history = recent;
    _preferences.write('play-history', jsonEncode(_history));
    _trial = trial;
    _status = trial ? '当前音源为试听片段' : '正在播放：' + _text(_current['title']);
    _loading = false;
    _emit();
  }

  /// :445-454。恢复会话期间保留待恢复位置（:446-448），其余情况清空。
  /// generation 非空时同样按 valid(generation) 拦截迟到回调（:442）。
  void fail(String error, {int? generation}) {
    if (generation != null && generation != _generation) {
      return;
    }
    if (!_restoringSession) {
      _resumePosition = null;
    }
    _failed = true;
    _status = error;
    _loading = false;
    _emit();
  }

  /// :456-469。重新准备当前曲目并恢复位置；尝试次数上限 2 由 tick 的门禁控制（:508-513）。
  void _recoverPlayback() {
    ++_recoveryAttempts;
    final generation = ++_generation;
    _resumePosition = _number(_state['position']);
    _resumePaused = !_flag(_state['requested']);
    _loading = true;
    _failed = false;
    _status = '正在恢复播放（' + _recoveryAttempts.toString() + '/2）…';
    _media.mediaControl('stop');
    _emit();
    _engine.prepare(_current, generation, reload: true);
  }
}
