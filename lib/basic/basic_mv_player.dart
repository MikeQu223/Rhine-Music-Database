import 'dart:async';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

/// 关联 MV 的视频面（Android 上唯一的真实解码路径）。
///
/// Qt 把 MV 放进独立的 960×790 窗口（`Qt/qml/MvWindow.qml`），且
/// `Qt/src/PlatformFeatures.h:23-27` 的 `MusicVideo = !RHINE_MOBILE && ...` 让整条
/// 路径在 Android 上恒关——所以「手机端能看 MV」在本仓库是新增能力，不是移植：
/// 用 Flutter 原生 `video_player`（Android 走 ExoPlayer），画面铺满整屏，
/// 控制条自己画，几何与 [portrait_pages_mv] 的状态页共用同一套动作串。
///
/// 声音恒静音：Qt `MvController` 刻意不建 QAudioOutput（`m_muted = true`，音乐由
/// 播放器自己出声），MV 只做画面跟随，所以这里 `setVolume(0)`。
class BasicMvPlayer extends StatefulWidget {
  const BasicMvPlayer({
    super.key,
    required this.url,
    required this.title,
    required this.status,
    required this.targetPositionMs,
    required this.playing,
    required this.offsetMs,
    required this.onClose,
    this.onOffsetChanged,
    this.onSync,
  });

  /// 视频地址（插件 `mv` 操作返回的 `url`）。
  final String url;

  /// 标题（曲目名，显示在顶部）。
  final String title;

  /// 状态串（领域层拼好的原文，原样显示）。
  final String status;

  /// 音乐侧当前播放位置（毫秒）。视频按它 + [offsetMs] 对齐。
  final double targetPositionMs;

  /// 音乐是否在播放（决定视频播放/暂停）。
  final bool playing;

  /// 画面偏移（毫秒，正数=画面提前）。
  final int offsetMs;

  final VoidCallback onClose;

  /// 微调偏移（毫秒）。宿主转给 `MvController.adjustOffset`。
  final ValueChanged<int>? onOffsetChanged;

  /// 手动重新对齐（宿主转给 `MvController.syncToMusic`）。
  final VoidCallback? onSync;

  @override
  State<BasicMvPlayer> createState() => _BasicMvPlayerState();
}

class _BasicMvPlayerState extends State<BasicMvPlayer> {
  VideoPlayerController? _controller;
  bool _ready = false;
  String _error = '';
  Timer? _sync;

  /// 对齐阈值：音乐与画面差超过它就 seek 一次。
  ///
  /// 400ms 与 Qt `MvController::syncToMusic` 的判据同源（播放中 400ms、暂停 100ms），
  /// 这里取播放中的那一档：暂停时画面停住不需要频繁对齐。
  static const int _driftToleranceMs = 400;

  @override
  void initState() {
    super.initState();
    unawaited(_open());
    _sync = Timer.periodic(const Duration(milliseconds: 500), (_) => _align(force: false));
  }

  @override
  void didUpdateWidget(covariant BasicMvPlayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url) {
      unawaited(_open());
      return;
    }
    if (oldWidget.playing != widget.playing) {
      _applyPlaying();
    }
  }

  @override
  void dispose() {
    _sync?.cancel();
    final VideoPlayerController? controller = _controller;
    _controller = null;
    if (controller != null) {
      unawaited(controller.dispose());
    }
    super.dispose();
  }

  Future<void> _open() async {
    final VideoPlayerController? previous = _controller;
    _controller = null;
    if (previous != null) {
      unawaited(previous.dispose());
    }
    if (mounted) {
      setState(() {
        _ready = false;
        _error = '';
      });
    }
    if (widget.url.isEmpty) {
      return;
    }
    final VideoPlayerController controller = VideoPlayerController.networkUrl(
      Uri.parse(widget.url),
    );
    _controller = controller;
    try {
      await controller.initialize();
      await controller.setVolume(0);
      await controller.setLooping(false);
      _align(force: true);
      _applyPlaying();
      if (!mounted || _controller != controller) {
        return;
      }
      setState(() => _ready = true);
    } on Object catch (error) {
      if (!mounted || _controller != controller) {
        return;
      }
      setState(() => _error = '视频解码失败：$error');
    }
  }

  void _applyPlaying() {
    final VideoPlayerController? controller = _controller;
    if (controller == null || !controller.value.isInitialized) {
      return;
    }
    if (widget.playing) {
      unawaited(controller.play());
    } else {
      unawaited(controller.pause());
    }
  }

  /// 把画面挪到「音乐位置 + 偏移」。漂移小于阈值时不动，避免每帧 seek 抽搐。
  void _align({required bool force}) {
    final VideoPlayerController? controller = _controller;
    if (controller == null || !controller.value.isInitialized) {
      return;
    }
    final Duration target = Duration(
      milliseconds: (widget.targetPositionMs + widget.offsetMs).round().clamp(0, 1 << 31),
    );
    final Duration duration = controller.value.duration;
    final Duration clamped = target > duration ? duration : target;
    final int drift = (controller.value.position - clamped).inMilliseconds.abs();
    if (force || drift > _driftToleranceMs) {
      unawaited(controller.seekTo(clamped));
    }
  }

  @override
  Widget build(BuildContext context) {
    final VideoPlayerController? controller = _controller;
    final bool showVideo = _ready && controller != null && controller.value.isInitialized;
    return ColoredBox(
      color: const Color(0xFF0A0D0B),
      child: SafeArea(
        child: Stack(
          fit: StackFit.expand,
          children: <Widget>[
            Center(
              child: showVideo
                  ? AspectRatio(
                      aspectRatio: controller.value.aspectRatio <= 0
                          ? 16 / 9
                          : controller.value.aspectRatio,
                      child: VideoPlayer(controller),
                    )
                  : Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 24),
                      child: Text(
                        _error.isNotEmpty ? _error : '正在载入 MV…',
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: Color(0xFFB9C2B4), fontSize: 14),
                      ),
                    ),
            ),
            Positioned(
              left: 0,
              right: 0,
              top: 0,
              child: Container(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: <Color>[Color(0xCC000000), Color(0x00000000)],
                  ),
                ),
                child: Row(
                  children: <Widget>[
                    IconButton(
                      onPressed: widget.onClose,
                      icon: const Icon(Icons.close, color: Color(0xFFE6E8DB)),
                      tooltip: '关闭 MV',
                    ),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Text(
                            widget.title.isEmpty ? '关联 MV' : widget.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Color(0xFFE6E8DB),
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          if (widget.status.isNotEmpty)
                            Text(
                              widget.status,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(color: Color(0xFF9AA394), fontSize: 11),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: Container(
                padding: const EdgeInsets.fromLTRB(12, 16, 12, 12),
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.bottomCenter,
                    end: Alignment.topCenter,
                    colors: <Color>[Color(0xCC000000), Color(0x00000000)],
                  ),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: <Widget>[
                    TextButton(
                      onPressed: () => widget.onOffsetChanged?.call(-500),
                      child: const Text('画面 −0.5s'),
                    ),
                    TextButton(
                      onPressed: () => widget.onOffsetChanged?.call(500),
                      child: const Text('画面 +0.5s'),
                    ),
                    TextButton(
                      onPressed: () {
                        widget.onSync?.call();
                        _align(force: true);
                      },
                      child: const Text('重新对齐'),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
