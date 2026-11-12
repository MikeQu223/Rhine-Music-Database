/// BASIC-89 lane B：真实音频播放的 Dart 端口（唯一实现：Android 系统 MediaPlayer）。
///
/// 分工（与既有 lib/platform/media_session.dart 的边界）：
///  - 本文件是**播放权威的 Dart 面**：prepare / play / pause / seekTo / stop / dispose 直接落到
///    Kotlin 的 android.media.MediaPlayer（android/.../basic/BasicAudioChannel.kt），状态由平台
///    推上来，Dart 不产生任何播放状态。
///  - lib/platform/media_session.dart 是**系统媒体控件的上报面**：MediaSession、通知、音频焦点。
///    它不产生声音，也不接收本文件的命令。把 BasicAudioState 摘要（playing/position/duration）
///    交给 MediaSessionChannel.update 是调用方（lane A 的 BasicController）的事，本文件不反向
///    调用 MediaSessionChannel——否则一条暂停会有两次写（收到 pause 再上报 pause）。
///
/// 真值源（Qt）：
///  - Qt/src/AudioPlayer.cpp:382-429  control(action, value) 的 pause / resume / stop / seek 分支；
///    :419-421 seek 目标夹到 [0, duration]。
///  - Qt/src/AudioPlayer.cpp:430-443  state() 的键集（playing/position/duration/seekable/volume/
///    ended/error/recoverable/requested/buffering）。本文件只取基本版需要的子集，并把 Qt 的
///    requested/buffering 化简为 buffering，把 ended 序号化简为 completed 布尔。
///  - Qt/src/MusicPlayer.cpp:301-443  prepare(track, generation, reload) 与 :442 的
///    valid(generation)：迟到回调必须丢弃。本文件用 generation 在 Dart 侧再拦一次平台推上来的
///    旧代事件，Kotlin 侧另有 epoch 令牌拦旧实例的原生回调。
///
/// 通道（名字是跨语言契约，Kotlin 侧 BasicAudioChannel 的同名常量逐字对应）：
///  - MethodChannel "rhine.music.database/basic_audio"
///      prepare(url, generation) / play(generation) / pause(generation) /
///      seekTo(positionMs, generation) / stop() / dispose() / getState()
///    每个方法都返回一份状态 map（与事件同构），Dart 拿到就刷新本地快照。
///  - EventChannel "rhine.music.database/basic_audio_state"
///    状态 map：playing / buffering / completed / positionMs / durationMs / generation / error。
///
/// 位置与时长的来源：Kotlin 侧只读 MediaPlayer.currentPosition / duration，不做算术外推；
/// 本文件同样不插值、不自己计时，位置只在平台推来新读数时变化。
///
/// 失效语义（本文件对异常的唯一处理方式）：
///  - 平台缺失（MissingPluginException）、PlatformException、通道其它异常 → 状态里写入 error，
///    不抛给调用方；播放标志同时归 false（没有声音却显示"正在播放"是更坏的谎）。
///  - dispose 之后所有方法都是安全的空操作（不抛、不再发平台调用、不再通知 listener）。
///    这与 MethodChannelMediaSession.dispose 后抛 StateError 的选择不同：播放端口被控制器在
///    widget 销毁链路里调用，抛异常会让一次 normal dispose 变成一次崩溃上报。
library;

import 'dart:async';

import 'package:flutter/services.dart';

/// Kotlin 侧 BasicAudioChannel.METHOD_CHANNEL 的逐字对应。
const String basicAudioChannel = 'rhine.music.database/basic_audio';

/// Kotlin 侧 BasicAudioChannel.EVENT_CHANNEL 的逐字对应。
const String basicAudioStateChannel = 'rhine.music.database/basic_audio_state';

/// 一次真实播放状态的不可变快照。
///
/// 七个字段与 Kotlin 侧状态 map 的键逐字对应（platform_playback.dart 与 BasicAudioChannel.kt
/// 的 snapshot()）：playing / buffering / completed / positionMs / durationMs / generation / error。
///
/// positionMs 与 durationMs 是**平台读数**，不是推算值：没有播放器时两者都是 0，暂停后停在
/// 最后一次真实读到的位置。
class BasicAudioState {
  const BasicAudioState({
    this.playing = false,
    this.buffering = false,
    this.completed = false,
    this.positionMs = 0,
    this.durationMs = 0,
    this.generation = 0,
    this.error = '',
  });

  /// 空闲态：没有音源、没有错误、第 0 代。
  static const BasicAudioState idle = BasicAudioState();

  final bool playing;
  final bool buffering;
  final bool completed;
  final double positionMs;
  final double durationMs;
  final int generation;
  final String error;

  /// 是否处于失败态（error 非空）。失败后必须先 prepare 新一代，play 不会静默复活。
  bool get hasError => error.isNotEmpty;

  BasicAudioState copyWith({
    bool? playing,
    bool? buffering,
    bool? completed,
    double? positionMs,
    double? durationMs,
    int? generation,
    String? error,
  }) {
    return BasicAudioState(
      playing: playing ?? this.playing,
      buffering: buffering ?? this.buffering,
      completed: completed ?? this.completed,
      positionMs: positionMs ?? this.positionMs,
      durationMs: durationMs ?? this.durationMs,
      generation: generation ?? this.generation,
      error: error ?? this.error,
    );
  }

  /// 与 Kotlin 侧 snapshot() 同构的 map；测试与调试用，通道本身不收这个 map。
  Map<String, Object?> toMap() {
    return <String, Object?>{
      'playing': playing,
      'buffering': buffering,
      'completed': completed,
      'positionMs': positionMs,
      'durationMs': durationMs,
      'generation': generation,
      'error': error,
    };
  }

  /// 解析平台状态 map；非 map 返回 null（调用方据此忽略这一条，而不是伪造状态）。
  ///
  /// 数值容错沿用 Qt QJsonValue::toDouble 的方向：非数值取 0，负值取 0（位置/时长不可能为负）。
  /// 布尔只认 true（Qt QJsonValue::toBool 的语义：只有 JSON 布尔为真）。
  static BasicAudioState? tryParse(Object? value) {
    if (value is! Map) {
      return null;
    }
    final Object? rawError = value['error'];
    return BasicAudioState(
      playing: value['playing'] == true,
      buffering: value['buffering'] == true,
      completed: value['completed'] == true,
      positionMs: _millis(value['positionMs']),
      durationMs: _millis(value['durationMs']),
      generation: _count(value['generation']),
      error: rawError is String ? rawError : '',
    );
  }

  static double _millis(Object? value) {
    if (value is num) {
      final double parsed = value.toDouble();
      if (!parsed.isFinite || parsed < 0) {
        return 0;
      }
      return parsed;
    }
    return 0;
  }

  static int _count(Object? value) {
    if (value is num && value.isFinite) {
      return value.toInt();
    }
    return 0;
  }

  @override
  bool operator ==(Object other) {
    return other is BasicAudioState &&
        other.playing == playing &&
        other.buffering == buffering &&
        other.completed == completed &&
        other.positionMs == positionMs &&
        other.durationMs == durationMs &&
        other.generation == generation &&
        other.error == error;
  }

  @override
  int get hashCode {
    return Object.hash(
      playing,
      buffering,
      completed,
      positionMs,
      durationMs,
      generation,
      error,
    );
  }

  @override
  String toString() {
    return 'BasicAudioState(playing: $playing, buffering: $buffering, '
        'completed: $completed, positionMs: $positionMs, durationMs: $durationMs, '
        'generation: $generation, error: $error)';
  }
}

/// 播放端口（冻结契约，名字与签名不可改）。
///
/// prepare 必须带上调用方自己的 generation（每次换曲递增）；play / pause / seekTo 也带同一代，
/// 平台会丢弃旧代命令，Dart 侧在发出前就先丢一次。
abstract class BasicAudioPort {
  BasicAudioState get state;

  void addListener(void Function(BasicAudioState) listener);

  void removeListener(void Function(BasicAudioState) listener);

  Future<void> prepare(String url, {required int generation});

  Future<void> play({required int generation});

  Future<void> pause({required int generation});

  Future<void> seekTo(double positionMs, {required int generation});

  Future<void> stop();

  Future<void> dispose();
}

/// MethodChannel + EventChannel 的默认实现。
///
/// 构造即订阅 EventChannel（receiveBroadcastStream() 会立刻发 listen），所以平台侧 onListen
/// 补推的那一份快照不会漏掉。取消订阅（dispose）不会让平台释放播放实例——释放只由
/// dispose()/stop() 触发。
class MethodChannelBasicAudio implements BasicAudioPort {
  MethodChannelBasicAudio({
    MethodChannel? methodChannel,
    EventChannel? eventChannel,
  })  : _methodChannel = methodChannel ?? const MethodChannel(basicAudioChannel),
        _eventChannel = eventChannel ?? const EventChannel(basicAudioStateChannel) {
    _subscription = _eventChannel.receiveBroadcastStream().listen(
          _onPlatformState,
          onError: _onPlatformError,
        );
  }

  final MethodChannel _methodChannel;
  final EventChannel _eventChannel;

  final List<void Function(BasicAudioState)> _listeners =
      <void Function(BasicAudioState)>[];

  BasicAudioState _state = BasicAudioState.idle;

  /// 最近一代：prepare 时**无条件**取调用方给的值（prepare 是调用方的新意图，不是迟到的旧命令），
  /// 平台事件/回包里更小的一律丢弃（valid(generation)）。
  ///
  /// 为什么要「无条件」而不是「只升不降」：真实 EventChannel 的 onListen 会立刻补推一份快照，
  /// authority 又是进程级单例，跨客户端复用；新 controller 的代际从 1 重新数，若在这里按
  /// 「小于已采纳代际就丢弃」处理，首曲的 prepare(1) 会被旧快照垫高的地板砖挡住，连通道都不发
  /// → 重进页面后第一首无声、第二首才恢复。Kotlin 侧对应的修法见 BasicAudioChannel 的
  /// onClientAttached()：新客户端接管时把 generation 归零，旧代快照不再出现。
  int _acceptedGeneration = 0;

  StreamSubscription<dynamic>? _subscription;
  bool _disposed = false;

  @override
  BasicAudioState get state => _state;

  /// dispose 之后为 true；此时所有播放方法是安全的空操作。
  bool get isDisposed => _disposed;

  @override
  void addListener(void Function(BasicAudioState) listener) {
    if (_disposed) {
      return;
    }
    _listeners.add(listener);
  }

  @override
  void removeListener(void Function(BasicAudioState) listener) {
    _listeners.remove(listener);
  }

  @override
  Future<void> prepare(String url, {required int generation}) async {
    if (_disposed) {
      return;
    }
    // 这里**不**做「generation 小于已采纳代际就丢弃」的判断：prepare 是新的播放意图，不是
    // 迟到的旧命令，代际大小在这里没有判别力。挡旧命令的是 play/pause/seekTo 的同代校验与
    // _onPlatformState 的旧事件丢弃。反过来说，若在这里按大小丢弃，重进页面/重建 controller 时
    // 首曲 prepare(1) 会被上一会话残留的大代际静默吞掉（连 MethodChannel 都不发）。
    if (url.isEmpty) {
      _setError('音频地址不可用');
      return;
    }
    _acceptedGeneration = generation;
    // 先落一份"正在加载"：这是本地意图，不是播放进度；位置与时长同时归零，等平台真读数。
    _publish(_state.copyWith(
      playing: false,
      buffering: true,
      completed: false,
      positionMs: 0,
      durationMs: 0,
      generation: generation,
      error: '',
    ));
    await _invoke('prepare', <String, Object?>{
      'url': url,
      'generation': generation,
    });
  }

  @override
  Future<void> play({required int generation}) async {
    if (_disposed || generation != _acceptedGeneration) {
      return;
    }
    await _invoke('play', <String, Object?>{'generation': generation});
  }

  @override
  Future<void> pause({required int generation}) async {
    if (_disposed || generation != _acceptedGeneration) {
      return;
    }
    await _invoke('pause', <String, Object?>{'generation': generation});
  }

  @override
  Future<void> seekTo(double positionMs, {required int generation}) async {
    if (_disposed || generation != _acceptedGeneration) {
      return;
    }
    // 夹取在 Dart 侧先做一次（上界用平台上一次报的真实时长），Kotlin 侧再按自己的 duration 夹一次。
    final double target = clampSeekPosition(positionMs, _state.durationMs);
    await _invoke('seekTo', <String, Object?>{
      'positionMs': target,
      'generation': generation,
    });
  }

  @override
  Future<void> stop() async {
    if (_disposed) {
      return;
    }
    await _invoke('stop');
  }

  @override
  Future<void> dispose() async {
    if (_disposed) {
      return;
    }
    _disposed = true;
    final StreamSubscription<dynamic>? subscription = _subscription;
    _subscription = null;
    await subscription?.cancel();
    // dispose 本身也要送达平台：让 Kotlin 侧立刻 release，而不是等下一次 prepare。
    await _invokeRaw('dispose');
    _publish(BasicAudioState.idle);
    _listeners.clear();
  }

  /// EventChannel 的兜底读法：向平台要一份真实快照（状态事件丢失/订阅晚于播放时用）。
  ///
  /// 返回 null 表示平台没给可解析的状态（通道缺失或回包不是 map）；此时状态里的 error 已经更新。
  Future<BasicAudioState?> refresh() async {
    if (_disposed) {
      return null;
    }
    final BasicAudioState? parsed =
        BasicAudioState.tryParse(await _invokeRaw('getState'));
    if (parsed == null) {
      return null;
    }
    if (parsed.generation < _acceptedGeneration) {
      return parsed;
    }
    _acceptedGeneration = parsed.generation;
    _publish(parsed);
    return parsed;
  }

  /// 平台事件：旧代丢弃，其余整份采纳（平台是唯一真值，不做字段级合并）。
  /// 已采纳代际可能被 prepare 拉低（见 _acceptedGeneration）：authority 在新客户端接管时把
  /// generation 归零，归零之后由它发出的每份快照都属于当前客户端，不存在「更大的旧代事件」。
  void _onPlatformState(Object? event) {
    if (_disposed) {
      return;
    }
    final BasicAudioState? parsed = BasicAudioState.tryParse(event);
    if (parsed == null) {
      return;
    }
    if (parsed.generation < _acceptedGeneration) {
      return;
    }
    _acceptedGeneration = parsed.generation;
    _publish(parsed);
  }

  void _onPlatformError(Object error, StackTrace stackTrace) {
    if (_disposed) {
      return;
    }
    if (error is MissingPluginException) {
      _setError('平台未实现 $basicAudioStateChannel 状态通道');
    } else if (error is PlatformException) {
      final String? message = error.message;
      _setError(message == null ? error.code : error.code + ': ' + message);
    } else {
      _setError('音频状态通道失败：$error');
    }
    // 事件流失效时补一次 getState：如果只是漏了一条事件，这一次就能把真实状态取回来。
    unawaited(refresh());
  }

  Future<void> _invoke(String method, [Map<String, Object?>? arguments]) async {
    final Object? reply = await _invokeRaw(method, arguments);
    final BasicAudioState? parsed = BasicAudioState.tryParse(reply);
    if (parsed == null) {
      return;
    }
    if (parsed.generation < _acceptedGeneration) {
      return;
    }
    _acceptedGeneration = parsed.generation;
    _publish(parsed);
  }

  /// 真正发平台调用并把异常折成 error 状态；返回平台原始回包（可能为 null）。
  Future<Object?> _invokeRaw(
    String method, [
    Map<String, Object?>? arguments,
  ]) async {
    try {
      return await _methodChannel.invokeMethod<Object?>(method, arguments);
    } on MissingPluginException {
      _setError('平台未实现 $basicAudioChannel 通道（$method）');
    } on PlatformException catch (error) {
      final String? message = error.message;
      _setError(message == null ? error.code : error.code + ': ' + message);
    } catch (error) {
      _setError('音频通道调用失败（$method）：$error');
    }
    return null;
  }

  void _setError(String message) {
    if (_disposed) {
      return;
    }
    if (_state.error == message) {
      return;
    }
    _publish(_state.copyWith(playing: false, buffering: false, error: message));
  }

  void _publish(BasicAudioState next) {
    if (next == _state) {
      return;
    }
    _state = next;
    // 复制一份再回调：listener 里 removeListener 不会破坏本次派发。
    final List<void Function(BasicAudioState)> snapshot =
        List<void Function(BasicAudioState)>.of(_listeners);
    for (final void Function(BasicAudioState) listener in snapshot) {
      listener(next);
    }
  }
}

/// seek 目标的夹取规则（与 Kotlin 侧 PlaybackAuthority.boundSeek 逐条一致）：
/// NaN → 0；负值/-∞ → 0；+∞ → duration（未知时 0）；超过上界 → duration；其余原样。
///
/// 上下界都来自平台报的真实时长：durationMs 为 0 表示还不知道时长，此时只夹下界。
double clampSeekPosition(double positionMs, double durationMs) {
  final double upper = durationMs > 0 ? durationMs : 0;
  if (positionMs.isNaN) {
    return 0;
  }
  if (positionMs == double.infinity) {
    return upper;
  }
  if (positionMs <= 0) {
    return 0;
  }
  if (upper > 0 && positionMs > upper) {
    return upper;
  }
  return positionMs;
}
