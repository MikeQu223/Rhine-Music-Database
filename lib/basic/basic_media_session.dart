/// Basic 播放面板与系统媒体控件（通知 / 锁屏 / 蓝牙按键）之间的最小适配器。
///
/// 这一层只做两件事：
///  1. 把 **真实** 的在播身份（BasicController 的 playingTrack）与 **真实** 的
///     音频读数（BasicAudioChannel 那唯一一个 MediaPlayer 回报的 BasicAudioState）
///     原样投给 lib/platform/media_session.dart；
///  2. 把平台推上来的动作串（pause/resume/next/prev/rhine.media.SEEK:<ms>）交回
///     同一个既有播放权威。
///
/// 它刻意 **不** 拥有：第二个 MediaPlayer、第二个 FlutterEngine、队列/目录副本、
/// 播放状态机、位置推算器、UI 选中行。位置只来自 native 读数，节流只决定"这次要不要
/// 把最新真实读数再报一次"，绝不外推；playing 严格等于 audio.playing，从不用
/// buffering/requested 冒充。

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../platform/media_session.dart';
import 'platform_playback.dart';

/// 在播身份：来自 BasicViewState.playingTrack（真实在播曲目），不是 UI 选中行。
///
/// [coverFilePath] 必须是 MediaSessionHost 能用 BitmapFactory.decodeFile 读到的
/// **本地文件路径**；没有本地封面时传 ''（通知栏就不显示封面，这是诚实的）。
/// 注意 SirenSong.cover 是远端 URL，永远不要塞进这里。
@immutable
class BasicMediaIdentity {
  const BasicMediaIdentity({
    required this.id,
    required this.title,
    this.artist = '',
    this.album = '',
    this.coverFilePath = '',
  });

  final String id;
  final String title;
  final String artist;
  final String album;
  final String coverFilePath;

  /// 没有可上报的身份（未播放 / 空队列）：调用方应保持 null 语义。
  bool get isEmpty => id.isEmpty || title.isEmpty;

  @override
  String toString() =>
      'BasicMediaIdentity($id, $title, $artist, $album, $coverFilePath)';
}

/// 系统媒体动作的唯一出口。
///
/// 实现方必须把每条命令交给既有播放权威（BasicController.togglePlay / next /
/// previous / seekToFraction + BasicAudioPort），不得在此新建状态、播放器或队列。
abstract interface class BasicMediaSessionCommands {
  /// 恢复播放（系统 PLAY）。实现应幂等：已在播放时不得变成暂停。
  Future<void> play();

  /// 暂停（系统 PAUSE）。实现应幂等：已暂停时不得变成播放。
  Future<void> pause();

  Future<void> next();

  Future<void> previous();

  /// 0..1 比例，与 BasicController.seekToFraction 同一入口；适配器已按真实
  /// durationMs 夹取，实现侧仍应自行 clamp。
  Future<void> seekToFraction(double fraction);
}

/// 真实读数 + 系统动作的最小桥；拥有传入的 [MediaSessionPort]。
///
/// 典型接法（141 在 BasicController 内）：
/// ```dart
/// _mediaSession = BasicMediaSessionAdapter.platform(commands: this);
/// // _publish() 里：
/// _mediaSession.sync(identity: _identityOf(playingTrack), audio: _audio.state);
/// // 真正开始播放（前台 Activity 链路）时：
/// await _mediaSession.ensureStarted();
/// // dispose() 里：
/// await _mediaSession.dispose();
/// ```
class BasicMediaSessionAdapter {
  BasicMediaSessionAdapter({
    required MediaSessionPort port,
    required BasicMediaSessionCommands commands,
    Duration positionRefreshInterval = const Duration(milliseconds: 1000),
    DateTime Function()? clock,
  })  : _port = port,
        _commands = commands,
        _positionRefreshInterval = positionRefreshInterval,
        _clock = clock ?? DateTime.now {
    // 构造即订阅：ensureStarted 之前平台也可能已经排了动作（pendingActions）。
    _actions = _port.actions.listen(
      _onAction,
      onError: (Object error) {
        _lastError = error;
      },
    );
  }

  /// 走真实通道（rhine.music.database/media_session[/events]）的默认装配。
  factory BasicMediaSessionAdapter.platform({
    required BasicMediaSessionCommands commands,
    Duration positionRefreshInterval = const Duration(milliseconds: 1000),
    DateTime Function()? clock,
  }) {
    return BasicMediaSessionAdapter(
      port: MethodChannelMediaSession(),
      commands: commands,
      positionRefreshInterval: positionRefreshInterval,
      clock: clock,
    );
  }

  static const String _seekPrefix = 'rhine.media.SEEK:';

  final MediaSessionPort _port;
  final BasicMediaSessionCommands _commands;
  final Duration _positionRefreshInterval;
  final DateTime Function() _clock;

  StreamSubscription<String>? _actions;
  MediaSessionState? _published;
  DateTime? _lastPublishAt;
  Object? _lastError;
  bool _started = false;
  bool _disposed = false;

  bool get disposed => _disposed;

  /// 平台已接受过 ensureStarted（不代表通知可见、不代表权限已授予）。
  bool get started => _started;

  /// 当前是否已上报了一条非空状态。
  bool get published => _published != null;

  /// 最近一次平台/命令失败；失败只记录，绝不向调用方抛。
  Object? get lastError => _lastError;

  /// 请求启动前台媒体服务。
  ///
  /// 返回 true 仅表示平台接受了请求（Activity 在前台且服务已拉起）；通知是否真的
  /// 可见取决于 POST_NOTIFICATIONS 授权，用户拒绝时播放与控件仍工作，只是静默。
  Future<bool> ensureStarted() async {
    if (_disposed) {
      return false;
    }
    if (_started) {
      return true;
    }
    try {
      final bool accepted = await _port.ensureStarted();
      if (!accepted) {
        // 平台拒绝启动（例如不在前台）：如实返回 false，不假装通知已挂上。
        _started = false;
        _lastError = StateError(
          'media foreground service start was rejected by the platform',
        );
        return false;
      }
      _started = true;
      _lastError = null;
      // 服务刚拉起时平台通知内容还是"未在播放"，清掉去重缓存逼下一次 sync 落地。
      _published = null;
      _lastPublishAt = null;
      return true;
    } catch (error) {
      _lastError = error;
      return false;
    }
  }

  /// 上报一次真实状态。
  ///
  /// [identity] 为空或 [audio] 处于失败态时不上报，并清掉上一轮通知（一次），
  /// 避免留下可点的旧元数据。任何平台异常都进 [lastError]，不抛给调用方。
  Future<void> sync({
    BasicMediaIdentity? identity,
    required BasicAudioState audio,
  }) async {
    if (_disposed) {
      return;
    }
    if (identity == null || identity.isEmpty || audio.hasError) {
      await _clearPublished();
      return;
    }
    final MediaSessionState desired = MediaSessionState(
      playing: audio.playing,
      positionMs: _ms(audio.positionMs),
      durationMs: _ms(audio.durationMs),
      title: identity.title,
      artist: identity.artist,
      album: identity.album,
      coverPath: identity.coverFilePath,
    );
    if (!_shouldPublish(desired)) {
      return;
    }
    try {
      await _port.update(desired);
      _published = desired;
      _lastPublishAt = _clock();
      _lastError = null;
    } catch (error) {
      // 保留旧 _published：下一次 sync 会再试，界面照真实读数走。
      _lastError = error;
    }
  }

  /// 显式停止：清空平台元数据与通知（前台服务本身由 native 生命周期决定）。
  Future<void> stop() async {
    if (_disposed) {
      return;
    }
    try {
      await _port.stop();
      _lastError = null;
    } catch (error) {
      _lastError = error;
      return;
    }
    _published = null;
    _lastPublishAt = null;
  }

  /// 取消动作订阅、清理已上报状态、释放端口；可重复调用，不抛。
  Future<void> dispose() async {
    if (_disposed) {
      return;
    }
    _disposed = true;
    final StreamSubscription<String>? actions = _actions;
    _actions = null;
    await actions?.cancel();
    if (_published != null) {
      try {
        await _port.stop();
      } catch (error) {
        _lastError = error;
      }
    }
    _published = null;
    _lastPublishAt = null;
    try {
      await _port.dispose();
    } catch (error) {
      _lastError = error;
    }
  }

  // [actions] 平台动作 -> 既有播放权威；这里不写状态、不回调 update。
  void _onAction(String action) {
    if (_disposed) {
      return;
    }
    if (action == 'pause') {
      _run(_commands.pause);
    } else if (action == 'resume') {
      _run(_commands.play);
    } else if (action == 'next') {
      _run(_commands.next);
    } else if (action == 'prev') {
      _run(_commands.previous);
    } else {
      _onSeek(action);
    }
  }

  void _onSeek(String action) {
    if (!action.startsWith(_seekPrefix)) {
      return;
    }
    final int? targetMs = int.tryParse(action.substring(_seekPrefix.length));
    if (targetMs == null) {
      return;
    }
    // 只按已上报的真实 duration 夹取；未知时长就丢弃，绝不猜一个位置。
    final int durationMs = _published?.durationMs ?? 0;
    if (durationMs <= 0) {
      return;
    }
    final int bounded = math.min(math.max(targetMs, 0), durationMs);
    _run(() => _commands.seekToFraction(bounded / durationMs));
  }

  // 命令失败只记录：异常一旦溢出平台回调会打断 EventChannel 的错误流。
  void _run(Future<void> Function() command) {
    Future<void> pending;
    try {
      pending = command();
    } catch (error) {
      // 同步抛出同样不能溢出平台回调，统一记进 lastError。
      _lastError = error;
      return;
    }
    pending.catchError((Object error) {
      _lastError = error;
    });
  }

  Future<void> _clearPublished() async {
    if (_published == null) {
      return;
    }
    try {
      await _port.stop();
      _lastError = null;
    } catch (error) {
      _lastError = error;
      return;
    }
    _published = null;
    _lastPublishAt = null;
  }

  // 节流只决定"要不要把最新真实读数再报一次"：位置以外的字段一变就必须报；
  // 只有位置在动时按刷新间隔抑制。
  bool _shouldPublish(MediaSessionState next) {
    final MediaSessionState? prev = _published;
    if (prev == null) {
      return true;
    }
    final bool sameContent = prev.playing == next.playing &&
        prev.title == next.title &&
        prev.artist == next.artist &&
        prev.album == next.album &&
        prev.coverPath == next.coverPath &&
        prev.durationMs == next.durationMs;
    if (!sameContent) {
      return true;
    }
    if (prev.positionMs == next.positionMs) {
      return false;
    }
    final DateTime? last = _lastPublishAt;
    return last == null ||
        _clock().difference(last) >= _positionRefreshInterval;
  }

  static int _ms(double value) {
    if (!value.isFinite || value <= 0) {
      return 0;
    }
    return value.round();
  }
}
