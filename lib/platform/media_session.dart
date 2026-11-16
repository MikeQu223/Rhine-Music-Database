/// Dart 侧媒体会话门面（T25-S01）。
///
/// 这一层只负责三件事：
///  1. 把一次媒体状态快照序列化成平台通道的 map；
///  2. 调用 Kotlin 侧的 ensureStarted / update / stop；
///  3. 把平台推上来的动作串原样广播给 Dart 消费者。
///
/// 它不拥有播放状态，也不实现播放状态机；收到动作后不会反向调用 update，
/// 因此不存在"收到 pause 再上报 pause"的双重写。真正的状态与通知仍由
/// MediaSessionHost.kt 和 MediaPlaybackService.kt 持有。
///
/// 与 lib/domain/models/media_snapshot.dart 的 MediaSnapshot 的区别：
/// MediaSnapshot 是 UI 域模型（元数据为非空 String，带 isStandby/copyWith），
/// 这里的 MediaSessionState 是通道 DTO（元数据允许 null，用来表达"本次没有
/// 更新该字段"）。两者字段同名但语义不同，故意不复用，避免域模型被通道协议绑死。
library;

import 'dart:async';

import 'package:flutter/services.dart';

/// Kotlin 侧 MediaSessionChannel.METHOD_CHANNEL 的逐字对应。
const String mediaSessionMethodChannelName =
    'rhine.music.database/media_session';

/// Kotlin 侧 MediaSessionChannel.EVENT_CHANNEL 的逐字对应。
const String mediaSessionEventChannelName =
    'rhine.music.database/media_session/events';

/// 一次媒体状态上报的不可变通道 DTO。
///
/// positionMs 与 durationMs 必须非负；元数据允许为 null，表示本次没有该字段的值。
class MediaSessionState {
  const MediaSessionState({
    required this.playing,
    required this.positionMs,
    required this.durationMs,
    this.title,
    this.artist,
    this.album,
    this.coverPath,
  })  : assert(positionMs >= 0, 'positionMs must not be negative'),
        assert(durationMs >= 0, 'durationMs must not be negative');

  final bool playing;
  final int positionMs;
  final int durationMs;
  final String? title;
  final String? artist;
  final String? album;
  final String? coverPath;

  /// 平台通道的 update 参数；键名与 MediaSessionChannel.update 的读取键逐字一致。
  Map<String, Object?> toMap() {
    return <String, Object?>{
      'playing': playing,
      'positionMs': positionMs,
      'durationMs': durationMs,
      'title': title,
      'artist': artist,
      'album': album,
      'coverPath': coverPath,
    };
  }

  @override
  bool operator ==(Object other) {
    return other is MediaSessionState &&
        other.playing == playing &&
        other.positionMs == positionMs &&
        other.durationMs == durationMs &&
        other.title == title &&
        other.artist == artist &&
        other.album == album &&
        other.coverPath == coverPath;
  }

  @override
  int get hashCode {
    return Object.hash(
      playing,
      positionMs,
      durationMs,
      title,
      artist,
      album,
      coverPath,
    );
  }
}

/// 媒体会话端口：UI/业务层只依赖这个接口，测试可以注入 fake。
abstract interface class MediaSessionPort {
  /// 请求启动前台媒体服务；只应从前台 Activity 链路调用。
  ///
  /// 返回 true 仅表示平台受理了这次启动请求，**不代表通知已显示**（还取决于
  /// POST_NOTIFICATIONS 授权）；返回 false 表示系统拒绝了启动（例如应用不在前台），
  /// 此时播放与控制照常，只是没有常驻通知。
  Future<bool> ensureStarted();

  /// 上报一次状态；每次调用只产生一次平台调用。
  Future<void> update(MediaSessionState state);

  /// 停止播放状态、清空元数据并更新通知，但不结束前台服务。
  ///
  /// 这是"没有在播内容"的收尾语义：调用后通知不得再挂着上一首的标题或可点的
  /// 播放/下一首动作（Kotlin 侧 MediaSessionHost.stop 会清元数据）。
  Future<void> stop();

  /// 平台动作流："pause" / "resume" / "next" / "prev" / "rhine.media.SEEK:<ms>"。
  ///
  /// SEEK 后面是系统给的**绝对毫秒**（可能越界或为负），消费方必须按真实 duration
  /// 夹取后才能使用；方向键/耳机键与锁屏按钮走同一条串。
  Stream<String> get actions;

  /// 退订动作流并释放通道资源；可重复调用。端口被释放后其余方法不得再调。
  Future<void> dispose();
}

/// 基于 MethodChannel / EventChannel 的默认实现。
///
/// 通道实例可注入，便于测试替换；不注入时使用上面两个固定通道名。
/// actions 是广播流：多个监听者共享同一个 EventChannel 订阅，最后一个监听者
/// 取消时才退订；dispose 之后所有方法和 actions 都抛 StateError。
class MethodChannelMediaSession implements MediaSessionPort {
  MethodChannelMediaSession({
    MethodChannel? methodChannel,
    EventChannel? eventChannel,
  })  : _methodChannel =
            methodChannel ?? const MethodChannel(mediaSessionMethodChannelName),
        _eventChannel =
            eventChannel ?? const EventChannel(mediaSessionEventChannelName);

  final MethodChannel _methodChannel;
  final EventChannel _eventChannel;

  StreamController<String>? _controller;
  StreamSubscription<dynamic>? _subscription;
  bool _disposed = false;

  /// 通道是否已释放；释放后 [actions] / apply 方法都抛 StateError。
  bool get isDisposed => _disposed;

  @override
  Stream<String> get actions {
    _checkNotDisposed();
    return (_controller ??= StreamController<String>.broadcast(
      onListen: _startActions,
      onCancel: _stopActions,
    ))
        .stream;
  }

  @override
  Future<bool> ensureStarted() async {
    _checkNotDisposed();
    final bool? started =
        await _methodChannel.invokeMethod<bool>('ensureStarted');
    return started ?? false;
  }

  @override
  Future<void> update(MediaSessionState state) async {
    _checkNotDisposed();
    await _methodChannel.invokeMethod<void>('update', state.toMap());
  }

  @override
  Future<void> stop() async {
    _checkNotDisposed();
    await _methodChannel.invokeMethod<void>('stop');
  }

  void _startActions() {
    if (_disposed || _subscription != null) {
      return;
    }
    _subscription = _eventChannel.receiveBroadcastStream().listen(
      (dynamic event) {
        if (event is String) {
          _controller?.add(event);
        }
      },
      onError: (Object error, StackTrace stackTrace) {
        _controller?.addError(error, stackTrace);
      },
    );
  }

  Future<void> _stopActions() async {
    final subscription = _subscription;
    _subscription = null;
    await subscription?.cancel();
  }

  /// 取消 EventChannel 订阅并关闭广播控制器；可重复调用。
  @override
  Future<void> dispose() async {
    if (_disposed) {
      return;
    }
    _disposed = true;
    await _stopActions();
    final controller = _controller;
    _controller = null;
    if (controller != null && !controller.isClosed) {
      await controller.close();
    }
  }

  void _checkNotDisposed() {
    if (_disposed) {
      throw StateError('MethodChannelMediaSession has been disposed');
    }
  }
}
