import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app/orientation_state.dart';
import '../hud/input/hit_layer.dart';
import '../hud/protocol/hud_frame.dart';
import '../ui/layout/portrait_stage.dart';
import 'basic_hud.dart';
import 'basic_hud_resources.dart';
import 'basic_models.dart';
import 'platform_playback.dart';
import 'siren_controller.dart';

/// 组合根：字形资源 + 唯一 controller → HUD 业务外壳。
///
/// 依赖全部可注入（测试只写不跑，注入 fake 即可离线构图）；生产路径用
/// [BasicController] + [MethodChannelBasicAudio]。
///
/// 与 BASIC-APK-92 的差别（RUNTIME-FIX-94，用户直接要求）：
///  - 不再挂 ConsentPage/ConsentGate 预览门：本 build 没有任何遥测 SDK 要授权，
///    未接遥测的启动弹窗只会吞掉首屏。全局隐私模块文件保留、其它入口不动。
///  - initState 里除了装载字形资源，还**恰好一次** [BasicController.boot]；
///    92 只 `_loadResources`，曲库永远是空的（空列表、点击无反应）。
class BasicApp extends StatefulWidget {
  const BasicApp({super.key, this.controller, this.audio, this.bundle});

  final BasicController? controller;
  final BasicAudioPort? audio;
  final AssetBundle? bundle;

  @override
  State<BasicApp> createState() => _BasicAppState();
}

class _BasicAppState extends State<BasicApp> {
  late final BasicAudioPort _audio;
  late final BasicController _controller;
  BasicHudResources? _resources;
  String _resourceError = '';
  bool _bootFailed = false;
  String _bootError = '';

  @override
  void initState() {
    super.initState();
    // 旋转只重建 widget，不重建 State：audio/controller 在这里创建一次。
    _audio = widget.audio ?? MethodChannelBasicAudio();
    _controller = widget.controller ?? BasicController(audio: _audio);
    unawaited(_boot());
    unawaited(_loadResources());
  }

  /// 唯一一次启动：boot 自身幂等（_booted），这里也只在 initState 调用。
  Future<void> _boot() async {
    try {
      await _controller.boot();
    } on Object catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _bootFailed = true;
        _bootError = error.toString();
      });
    }
  }

  Future<void> _loadResources() async {
    try {
      final BasicHudResources resources = await BasicHudResources.load(bundle: widget.bundle);
      if (!mounted) {
        return;
      }
      setState(() {
        _resources = resources;
        _resourceError = '';
      });
    } on Object catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _resourceError = error.toString();
      });
    }
  }

  void _retryResources() {
    setState(() {
      _resourceError = '';
      _resources = null;
    });
    unawaited(_loadResources());
  }

  void _retryBoot() {
    setState(() {
      _bootFailed = false;
      _bootError = '';
    });
    // boot 已置 _booted，真正的重读入口是 retry()（未加载过曲库时重读曲库）。
    unawaited(_controller.retry());
  }

  @override
  void dispose() {
    if (widget.controller == null) {
      _controller.dispose();
    }
    if (widget.audio == null) {
      unawaited(_audio.dispose());
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: basicLibraryName,
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        useMaterial3: false,
        scaffoldBackgroundColor: Colors.black,
      ),
      home: _home(),
    );
  }

  Widget _home() {
    if (_bootFailed) {
      return _BasicMessage(
        text: '曲库启动失败：$_bootError',
        actionLabel: '重试',
        onAction: _retryBoot,
      );
    }
    if (_resourceError.isNotEmpty) {
      return _BasicMessage(
        text: '字形资源装载失败：$_resourceError',
        actionLabel: '重试',
        onAction: _retryResources,
      );
    }
    final BasicHudResources? resources = _resources;
    if (resources == null) {
      return const _BasicMessage(text: '正在装载字形资源…');
    }
    return BasicShell(controller: _controller, resources: resources);
  }
}

/// 业务外壳：唯一 controller 实例；横竖屏只重排，不重建 controller/音频。
class BasicShell extends StatelessWidget {
  const BasicShell({super.key, required this.controller, required this.resources});

  final BasicController controller;
  final BasicHudResources resources;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (BuildContext context, Widget? _) {
        final BasicViewState state = controller.state;
        return PopScope(
          canPop: state.phase == BasicPhase.library,
          onPopInvoked: (bool didPop) {
            if (didPop) {
              return;
            }
            if (state.phase == BasicPhase.lyrics) {
              unawaited(controller.closeLyrics());
              return;
            }
            if (state.phase == BasicPhase.detail) {
              unawaited(controller.back());
            }
          },
          child: Scaffold(
            backgroundColor: Colors.black,
            body: LayoutBuilder(
              builder: (BuildContext context, BoxConstraints constraints) {
                final double width = constraints.maxWidth;
                final double height = constraints.maxHeight;
                final OrientationKind kind =
                    classifyOrientation(logicalWidth: width, logicalHeight: height);
                final Widget surface = kind == OrientationKind.portrait
                    ? BasicHudSurface(
                        state: state,
                        ports: resources.ports,
                        onAction: (String action) => _onAction(context, action),
                      )
                    : _landscape(state, width, height, context);
                if (kind == OrientationKind.portrait) {
                  /// 竖屏：PortraitStage 注入同一套 stage 坐标（绘制与命中共用）；
                  /// 顶部 1080 设计高度留给 3D 场景（见 basicSceneStageRect）。
                  return PortraitStage(child: surface);
                }
                return surface;
              },
            ),
          ),
        );
      },
    );
  }

  Widget _landscape(BasicViewState state, double width, double height, BuildContext context) {
    final StageGeometry geometry = StageGeometry(logicalWidth: width, logicalHeight: height);
    final HudStage stage = HudStage(
      scale: geometry.stageScale,
      width: geometry.stageWidth,
      height: StageGeometry.baseHeight,
    );
    return BasicHudSurface(
      state: state,
      ports: resources.ports,
      onAction: (String action) => _onAction(context, action),
      geometry: geometry,
      stage: stage,
    );
  }

  Future<void> _onAction(BuildContext context, String action) async {
    final BasicController controller = this.controller;
    final BasicViewState state = controller.state;
    switch (action) {
      case 'back':
      case 'music:parent':
        await controller.back();
        return;
      case 'retry':
      case 'player:lyrics-retry':
        await controller.retry();
        return;
      case 'player:toggle':
        await controller.togglePlay();
        return;
      case 'player:prev':
      case 'prev':
        await controller.previous();
        return;
      case 'player:next':
      case 'next':
        await controller.next();
        return;
      case 'player:lyrics':
        await controller.openLyrics();
        return;
      case 'player:lyrics-close':
        await controller.closeLyrics();
        return;
      case 'open':
        await _openIndex(state, basicSelectedItemIndex(state, basicLibraryItems(state)));
        return;
      case 'music:play-loaded':
        if (basicLibraryItems(state).isNotEmpty) {
          await _openIndex(state, 0);
        }
        return;

      /// 详情页主按钮（song_detail.dart:755 无条件产出的 'music:play'）：
      /// 从详情播放当前曲目（fresh 详情 → native prepare/play 由 controller 统一负责）。
      /// 没有当前曲目（尚未选中）时退化为播放条语义的 toggle，仍只走唯一 controller。
      case 'music:play':
        final SirenSong? detailSong = state.song;
        if (detailSong != null) {
          await controller.openSong(detailSong);
        } else {
          await controller.togglePlay();
        }
        return;

      /// archive 页第一屏的「在资料库中打开 →」（archive_page.dart:255）：
      /// 真实导航到当前 Siren 曲库（退出详情/歌词、清空检索词），不吞点击。
      case 'music:open-all-siren':
        await controller.openSirenLibrary();
        return;

      /// 顶部导航真实输入检索：弹输入框，提交后走唯一 controller 的 setQuery。
      case 'search':
        await _openSearch(context);
        return;

      /// 基础版尚未实现的入口：明确提示，而不是静默或伪造账号/设置状态。
      case 'settings':
        await _notice(context, '设置：基础版预览尚未接入，本 build 无账号与遥测。');
        return;
      case 'saved':
        await _notice(context, '收藏/保存：基础版预览尚未接入（不伪造账号会话）。');
        return;
      case 'discover':
        await _notice(context, '发现音乐：基础版预览尚未接入。');
        return;
      case 'music:directory-info':
        await _notice(context, state.status.isEmpty ? '塞壬唱片目录' : state.status);
        return;
      default:
        break;
    }
    if (action.startsWith('player:seek-fraction:')) {
      final double fraction =
          double.tryParse(action.substring('player:seek-fraction:'.length)) ?? double.nan;
      if (fraction.isFinite) {
        await controller.seekToFraction(fraction);
      }
      return;
    }
    if (action.startsWith('player:lyric-line:')) {
      final int index = int.tryParse(action.substring('player:lyric-line:'.length)) ?? -1;
      if (index >= 0 && index < state.lyrics.length && state.durationMs > 0) {
        await controller.seekToFraction(state.lyrics[index].startMs / state.durationMs);
      }
      return;
    }
    if (action.startsWith('music:index:') || action.startsWith('music:slot:')) {
      final int index = int.tryParse(action.substring(action.lastIndexOf(':') + 1)) ?? -1;
      await _openIndex(state, index);
      return;
    }
    if (action == 'column-prev' || action == 'column-next') {
      await _cycleAlbum(state, action == 'column-next' ? 1 : -1);
      return;
    }

    /// 音量：B 的 BasicAudioPort 没有 volume 契约。命中了真实热区就不能静默，
    /// 给一条明确的预览提示，但不伪造音量值/不假装已生效。
    if (action.startsWith('player:volume-fraction:')) {
      await _notice(context, '音量：基础版音频通道暂无音量契约，本 build 不伪造音量状态。');
      return;
    }

    /// 其余未接动作（点赞/模式切换：Siren 无账号与本地模式）保持无操作，绝不伪造状态。
  }

  /// 检索输入框：只把真实输入交给 [BasicController.setQuery]，不构造本地假结果。
  Future<void> _openSearch(BuildContext context) async {
    final String? submitted = await showDialog<String>(
      context: context,
      builder: (BuildContext dialogContext) =>
          _SearchDialog(initialQuery: controller.state.query),
    );
    if (submitted == null) {
      return;
    }
    await controller.setQuery(submitted);
    await _notice(context, controller.state.status);
  }

  Future<void> _notice(BuildContext context, String message) async {
    if (!context.mounted) {
      return;
    }
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content: Text(message, style: const TextStyle(color: Color(0xFFECECEC))),
        backgroundColor: const Color(0xFF1B1F24),
        duration: const Duration(seconds: 3),
      ),
    );
  }

  Future<void> _openIndex(BasicViewState state, int index) async {
    final List<BasicListItem> items = basicLibraryItems(state);
    if (index < 0 || index >= items.length) {
      return;
    }
    final BasicListItem item = items[index];
    if (item.kind == 'album') {
      if (item.index < state.albums.length) {
        await controller.openAlbum(state.albums[item.index]);
      }
      return;
    }
    if (item.index < state.songs.length) {
      await controller.openSong(state.songs[item.index]);
    }
  }

  Future<void> _cycleAlbum(BasicViewState state, int delta) async {
    if (state.albums.isEmpty) {
      return;
    }
    final String currentId = state.album?.id ?? '';
    final int current = state.albums.indexWhere((SirenAlbum album) => album.id == currentId);
    final int next = current < 0 ? 0 : (current + delta) % state.albums.length;
    await controller.openAlbum(state.albums[next < 0 ? next + state.albums.length : next]);
  }
}

class _BasicMessage extends StatelessWidget {
  const _BasicMessage({required this.text, this.actionLabel, this.onAction});

  final String text;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final String? label = actionLabel;
    final VoidCallback? action = onAction;
    return Scaffold(
      backgroundColor: Colors.black,
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text(
                text,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Color(0xFFECECEC), fontSize: 16),
              ),
              if (label != null && action != null) ...<Widget>[
                const SizedBox(height: 20),
                OutlinedButton(
                  onPressed: action,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: const Color(0xFFECECEC),
                    side: const BorderSide(color: Color(0xFF3A444A)),
                  ),
                  child: Text(label),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// 检索输入框自己持有 TextEditingController：弹窗退场动画期间输入框仍在树上，
/// 调用方提前 dispose 会触发 "used after being disposed"，所以生命周期交给 State。
class _SearchDialog extends StatefulWidget {
  const _SearchDialog({required this.initialQuery});

  final String initialQuery;

  @override
  State<_SearchDialog> createState() => _SearchDialogState();
}

class _SearchDialogState extends State<_SearchDialog> {
  late final TextEditingController _text;

  @override
  void initState() {
    super.initState();
    _text = TextEditingController(text: widget.initialQuery);
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: const Color(0xFF121417),
      title: const Text(
        '检索塞壬唱片',
        style: TextStyle(color: Color(0xFFECECEC), fontSize: 16),
      ),
      content: TextField(
        key: const Key('basic-search-field'),
        controller: _text,
        autofocus: true,
        style: const TextStyle(color: Color(0xFFECECEC)),
        decoration: const InputDecoration(
          hintText: '曲名 / 专辑 / 歌手',
          hintStyle: TextStyle(color: Color(0xFF6E7A80)),
        ),
        textInputAction: TextInputAction.search,
        onSubmitted: (String value) => Navigator.of(context).pop(value),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(_text.text),
          child: const Text('检索'),
        ),
      ],
    );
  }
}
