import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart' show Ticker;
import 'package:flutter/services.dart';

import '../data/storage/preference_store.dart' show PreferencePort;
import '../domain/collection/local_collection_store.dart';
import '../app/consent_gate.dart';
import '../app/orientation_state.dart';
import '../hud/input/hit_layer.dart';
import '../hud/input/key_router.dart'
    show
        EngineKeyOutcome,
        EngineKeyPorts,
        EngineKeyRouter,
        HudAction,
        HudKeyEvent,
        HudKeyOutcome,
        HudKeyPorts,
        HudKeyRouter,
        HudKeySnapshot,
        KeySymbol;
import '../hud/input/text_input_overlay.dart';
import '../hud/input/wheel_router.dart' show HudScrollOffsets, HudWheelConstants;
import '../hud/modals/disc_warning_modal.dart';
import '../hud/modals/settings_modal.dart'
    show
        PlatformCapabilities,
        SettingsOperatingSystem,
        SettingsPreferenceContext,
        SettingsPreferenceSnapshot;
import '../hud/modals/queue_modal.dart' show queueModalMaximumOffset;
import '../hud/player/player_bar.dart' show playerBarHeaderHeight, playerBarRowHeight;
import '../hud/portrait/portrait_pages_queue.dart' show portraitQueueModes;
import '../hud/portrait/portrait_pages_search_kinds.dart'
    show
        portraitSearchExpandActionPrefix,
        portraitSearchGroupActionPrefix,
        portraitSearchGroupBackAction,
        portraitSearchGroupKeys,
        portraitSearchKindActionOrder,
        portraitSearchKindKeys;
import '../hud/pages/viewer_hud.dart';
import '../hud/scale/hud_scale.dart';
import '../hud/protocol/hud_frame.dart';
import '../scene/viewer_state.dart';
import '../ui/layout/portrait_stage.dart';
import '../platform/media_session.dart';
import 'basic_art_cache.dart';
import 'basic_cover_images.dart';
import 'basic_cover_viewer.dart';
import 'basic_hud.dart';
import 'basic_plugins_portrait.dart';
import 'basic_hud_resources.dart';
import 'basic_models.dart';
import 'basic_player_preferences.dart';
import 'basic_settings.dart';
import 'basic_settings_runtime.dart';
import 'basic_settings_store.dart';
import 'basic_settings_view.dart';
import 'basic_settings_portrait.dart';
import 'basic_settings_window.dart';
import 'basic_startup_view.dart';
import '../plugin/plugin_models.dart';
import '../plugin/plugin_manager.dart';
import '../provider/provider_assets.dart';
import '../provider/provider_descriptor.dart';
import '../provider/provider_gateway.dart';
import '../provider/provider_registry.dart';
import 'platform_playback.dart';
import 'qt_scene_view.dart';
import 'siren_controller.dart';

/// 启动失败页的可见前缀。外壳与测试共用这一份字面量，避免两处文案漂移。
const String basicBootFailurePrefix = '曲库启动失败：';

/// 字形资源还在装载时的可见占位（不是“空曲库”，也不渲染半张 HUD）。
const String basicResourceLoadingText = '正在装载字形资源…';

/// 字形资源装载抛错时的可见前缀（[BasicHudResources.load] 自己从不抛错，这条是兜底）。
const String basicResourceFailurePrefix = '字形资源装载失败：';

/// 字形表缺失（[BasicHudResources.load] 把缺项记进 failures）时的可见前缀。
const String basicGlyphMissingPrefix = '字形资源缺失：';

/// 未接入动作的统一可见前缀。出现它 = 预览里点得到、但功能确实还没接，
/// 绝不静默 no-op，也不假装有设置/账号/歌单。
const String basicUnimplementedPrefix = '预览中尚未实现：';

/// 检索动作前缀：`search:<查询词>` → [BasicController.setQuery]。
///
/// 真实的文本输入控件是 lib/hud/input/text_input_overlay.dart:994 的 `TextInputOverlay`
/// （端口 :361 `TextInputPorts`）。裸 `search` 打开它（Qt/src/NativeHudController.cpp:684
/// 把 `search` 交给 openModal("search")），框里输入的字走 `TextInputPorts.query` →
/// [BasicController.setQuery]；`search:<词>` 这条动作载荷是 HUD 命中层的既有契约，两条都真实。
const String basicSearchActionPrefix = 'search:';

/// 列表为空时点“open”的可见反馈（不打开不存在的行）。
const String basicEmptyLibraryNotice = '列表为空：当前没有可打开的条目';

/// 进度跳转载荷前缀：`player:seek-fraction:<0..1>`（player_bar.dart 的 seek 命中）。
const String basicSeekFractionActionPrefix = 'player:seek-fraction:';

/// 列表行载荷前缀：`music:index:<i>`（track_ruler.dart:331 的非选中行）。
const String basicMusicIndexActionPrefix = 'music:index:';

/// 分类检索结果行的动作前缀（`basic_hud.dart` 的 `_portraitSearchRows` 发出）。
const String basicSearchAlbumActionPrefix = 'music:search-album:';
const String basicSearchPlaylistActionPrefix = 'music:search-playlist:';
const String basicSearchArtistActionPrefix = 'music:search-artist:';

/// 竖屏顶部来源 tab 的命中前缀：`mobile:lane:<lane>`。
const String basicPortraitLaneActionPrefix = 'mobile:lane:';

/// 竖屏检索页四列 tab 的命中前缀：`mobile:search-tab:<0..3>`。
const String basicPortraitSearchTabActionPrefix = 'mobile:search-tab:';

/// 竖屏队列页模式区展开/收起（Qt `mobile:queue-modes`，ResponsiveHudLayout.cpp:430-490）。
const String basicQueueModesAction = 'mobile:queue-modes';

/// 队列行载荷前缀：`player:queue:<i>`（选中并播放该行，Qt NativeHudController.cpp 的 "queue"）。
const String basicQueueRowActionPrefix = 'player:queue:';

/// 队列移除载荷前缀：`player:remove:<i>`（Qt NativeHudController.cpp 的 "remove"）。
const String basicQueueRemoveActionPrefix = 'player:remove:';

/// 播放模式载荷前缀：`player:mode:<off|all|one|shuffle>`（Qt NativeHudController.cpp 的 "mode"）。
const String basicQueueModeActionPrefix = 'player:mode:';

/// 清空待播（Qt NativeHudController.cpp 的 "clear" → player.clearUpcoming()）。
const String basicQueueClearAction = 'player:clear';

/// 音量载荷前缀：`player:volume-fraction:<0..1>`（player_bar.dart:529）。
/// 本版没有音量 API，命中必须给可见反馈，不能静默吃掉。
const String basicVolumeFractionActionPrefix = 'player:volume-fraction:';

/// 歌词行载荷前缀：`player:lyric-line:<i>`（94 已上线的歌词跳转热区）。
const String basicLyricLineActionPrefix = 'player:lyric-line:';

/// 选曲槽载荷前缀：`music:slot:<i>`（archive_page.dart:311，与 music:index: 同一份下标）。
const String basicMusicSlotActionPrefix = 'music:slot:';

/// 音乐平台行载荷前缀：`provider:<id>`（`lib/hud/portrait/portrait_pages_provider.dart`
/// 的平台行命中，切到该平台；找不到 id 时给可见反馈，不猜）。
const String basicProviderSwitchPrefix = 'provider:';

/// 组合根：唯一 [BasicController] + 字形资源 → HUD 业务外壳。
///
/// 责任边界（RUNTIME-STARTUP-96）：
/// * 生产依赖只在这里装配（[MethodChannelBasicAudio] + [BasicController]），两者都可注入；
///   注入方持有所有权，本 widget 只 dispose 自己创建的实例。
/// * 启动只有一条路：`State.initState` → [BasicController.boot] 恰一次。
///   boot 自身用内部 `_booted` 幂等；本 widget 也只在 initState 调一次，
///   所以旋转（同一个 State 重建）既不会二次 boot，也不会重建 audio/controller。
/// * 曲库与字形资源互不依赖，两路并行装载；谁先完成谁先 setState，
///   谁也不等谁，也不为对方加第二份 controller。
/// * 真实曲库错误不吞成空：controller 把 error/status 放进 [BasicViewState]，
///   外壳只负责显示；这里不把失败改写成空列表，也不伪造曲目。
/// * 命中动作只有两条出路：落到 [BasicController] 的真实方法，或给可见的
///   “尚未接入”反馈（[basicUnimplementedPrefix]）。绝不静默 no-op，也不假装
///   有设置/账号/歌单；需要新 controller API 的动作（如 music:open-all-siren）
///   在反馈里点名缺的契约，由父/94 决定是否补。
///
/// 与 APK-92 的差别（用户直接要求）：
/// * 92 的首屏先挂 ConsentPage，`onProceed` 只把 `_entered` 置 true，
///   同时**从不调用** [BasicController.boot] —— 曲库永远是空的，列表没有条目，
///   点击自然全部落空。现在 initState 里恰好一次 boot。
/// * 92 的启动弹窗没有任何授权对象：本 build 未捆绑需授权的遥测 SDK
///   （Clarity/Bugly 由 Qt 宿主 JNI 注入，不在 Dart 层），弹窗只会吞掉首屏。
///   预览因此不再经过 ConsentPage/ConsentGate，也绝不 start 任何 SDK；
///   公共隐私模块（lib/app/consent_gate.dart、lib/ui/pages/consent_page.dart）
///   原样保留给需要授权的入口。
class BasicApp extends StatefulWidget {
  const BasicApp({
    super.key,
    this.controller,
    this.audio,
    this.gate,
    this.bundle,
    this.mediaSessionPort,
    this.settingsPort,
  });

  /// 外部注入的 controller；注入方持有所有权（本 widget 不 dispose）。
  final BasicController? controller;

  /// 外部注入的音频端口；注入方持有所有权（本 widget 不 dispose）。
  final BasicAudioPort? audio;

  /// 仅为源码兼容保留的参数：[BasicApp] 的预览**不再**用 [ConsentGate] 拦截首屏，
  /// 也不会调用 [ConsentGate.start]/[ConsentGate.approve]。传进来的 gate
  /// 不参与任何分支（不读 snapshot、不读 phase、不注册回调），传 null 亦无影响。
  ///
  /// 保留它是因为其它 lane 的调用点仍按旧签名构造；删参数会把这些调用点
  /// 一起拖进本次修复。隐私模块本身没有删除，需要授权的入口继续自行使用。
  final ConsentGate? gate;

  /// 字形资源包；只有测试/离线预览需要注入，生产用 rootBundle。
  final AssetBundle? bundle;

  /// 系统媒体控件端口（通知/锁屏/蓝牙）。只有自己创建 controller 时才使用；
  /// 不注入就没有这层（桌面预览、widget 测试一律不碰平台通道）。
  final MediaSessionPort? mediaSessionPort;

  /// 面板偏好的真实端口（SharedPreferences）。生产留空 = 走平台通道
  /// [SharedPreferencesBasicSettingsPort]（2026-11-16 用户指示：设置参数用
  /// shared_preferences 保存）；widget 测试注入 [MemoryBasicSettingsPort]。
  final BasicSettingsPort? settingsPort;

  @override
  State<BasicApp> createState() => _BasicAppState();
}

class _BasicAppState extends State<BasicApp> {
  /// 唯一音频端口：initState 装配一次，跨旋转/重建不再新建。
  late final BasicAudioPort _audio;

  /// 唯一 controller：initState 装配一次，跨旋转/重建不再新建。
  late final BasicController _controller;

  /// 面板偏好存储：与设置页是同一份（`panel/<key>` 命名空间），跨旋转不重建。
  late final BasicSettingsStore _settingsStore;

  /// 播放器窄偏好（play-history / play-mode）：同步镜像 + 异步落盘。
  /// 必须在造 [BasicController] 之前就有实例（MusicPlayer 构造时同步读回模式）。
  late final BasicPlayerPreferences _playerPreferences =
      BasicPlayerPreferences(_settingsStore.port);

  /// 本机收藏（喜欢 / 自建歌单）的持久化实现。
  ///
  /// 端口是设置页那套 `BasicSettingsPort` 的适配：`LocalCollectionStore` 要的是
  /// 异步 `PreferencePort`（read/write/remove），而设置端口只按 `panel/` 前缀
  /// 直接落盘，所以要包一层把键拼成 `panel/collections/<provider>.json`。
  late final LocalCollectionStore _collections =
      LocalCollectionStore(port: _BasicSettingsPreferencePort(_settingsStore));

  BasicHudResources? _resources;
  Object? _resourceError;
  Object? _bootError;

  /// 所有权在 initState 一次定死：只有自己创建的依赖才由自己 dispose。
  /// 不读 widget.*（那是可变的）：否则父级把注入改成 null 时会把注入方的实例
  /// 一起 dispose（双重释放），或反过来漏掉自持实例（泄漏）。
  late final bool _ownsAudio;
  late final bool _ownsController;

  /// 回执接收面的稳定句柄：方法掏出来的 tear-off 每次都是新闭包，
  /// 直接拿 `_onSceneScroll` 做 identical() 判断永远不会相等，dispose 就摘不掉。
  late final ValueChanged<QtSceneScrollEvent> _sceneScrollHandler =
      _onSceneScroll;

  @override
  void initState() {
    super.initState();
    _settingsStore =
        BasicSettingsStore(port: widget.settingsPort ?? SharedPreferencesBasicSettingsPort());
    _ownsAudio = widget.audio == null;
    _ownsController = widget.controller == null;
    _audio = widget.audio ?? MethodChannelBasicAudio();
    // 系统媒体控件端口：显式注入优先；否则只在"自己造 controller + 自己造 audio"
    // 的生产装配里接平台通道（widget 测试一律注入依赖，因此不会碰通道）。
    final MediaSessionPort? mediaPort = widget.mediaSessionPort ??
        (widget.controller == null && widget.audio == null
            ? (kIsWeb ? null : MethodChannelMediaSession())
            : null);
    _controller = widget.controller ??
        BasicController(
          audio: _audio,
          mediaSessionPort: mediaPort,
          // 播放器的窄偏好（play-history / play-mode）与设置页共用 `panel/` 键空间：
          // 这里的端口在 [_attachPlayerPreferences] 里灌入已存值，之后同步内存镜像
          // + 异步落盘（MusicPlayer 的 PreferencePort 是同步契约）。
          preferences: _playerPreferences,
          // 收藏写入口（Qt LocalCollections 的写入面）。只读端口 `collections`
          // 也一并给上：BasicController._refreshLocalCollections 需要它。
          collectionStore: _collections,
          collections: _collections,
        );
    // 封面像素：控制器那份"URL → 私有目录里的真实图片文件"缓存同时供 HUD 使用，
    // 不新开第二条下载链路；解码完成的回调让宿主重绘一次（这一帧先画空槽）。
    final BasicArtCache? artCache = _controller.artCache;
    if (artCache != null) {
      _covers = BasicCoverImages(cache: artCache, onChanged: _onCoverDecoded);
    }
    // 3D 场景的连续滚动回执（拖动/惯性/滚轮）落到同一个 controller 窗口真值上：
    // 方向 B（3D → 列表/ruler）因此不依赖 HUD 是否接了 onScroll 参数。
    QtSceneScrollRouter.instance.handler = _sceneScrollHandler;
    // 两路互不依赖：曲库走网络，字形走 asset。并行启动，任一失败都不会互相取消。
    unawaited(_boot());
    unawaited(_loadResources());
  }

  /// Qt 把连续条目增量报回来：拖动/惯性中途即越过即进入（窗口保小数），松手才 commit 落行。
  void _onSceneScroll(QtSceneScrollEvent event) {
    if (!mounted) {
      return;
    }
    _controller.applyNativeArchiveScroll(
      event.deltaRows,
      committed: event.committed,
      started: event.started,
    );
  }

  /// 启动恰一次：`boot()` 内部幂等，但真正的“一次”由 initState 保证。
  Future<void> _boot() async {
    try {
      await _controller.boot();
    } on Object catch (error) {
      if (!mounted) {
        return;
      }
      setState(() => _bootError = error);
    }
  }

  Future<void> _loadResources() async {
    try {
      final BasicHudResources resources =
          await BasicHudResources.load(bundle: widget.bundle, covers: _covers);
      if (!mounted) {
        return;
      }
      setState(() {
        _resources = resources;
        _resourceError = null;
      });
    } on Object catch (error) {
      if (!mounted) {
        return;
      }
      setState(() => _resourceError = error);
    }
  }

  /// 封面像素缓存（真值来自控制器那份落盘缓存）；没有媒体端口时为 null。
  BasicCoverImages? _covers;

  void _onCoverDecoded() {
    if (mounted) {
      setState(() {});
    }
  }

  @override
  void didUpdateWidget(covariant BasicApp oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 依赖在 initState 装配，重建只换 description：所有权形态若变了，
    // 上面的 late final 已经和 widget 不一致（会双 dispose 或泄漏），必须当场炸。
    assert(
      (oldWidget.audio == null) == (widget.audio == null),
      'BasicApp.audio 的所有权形态不能在重建时改变（注入 ↔ 自建）。',
    );
    assert(
      (oldWidget.controller == null) == (widget.controller == null),
      'BasicApp.controller 的所有权形态不能在重建时改变（注入 ↔ 自建）。',
    );
  }

  /// boot 失败后的重试入口：boot 不能再跑（`_booted` 已置位），走 controller.retry()。
  Future<void> _retryBoot() async {
    if (!mounted) {
      return;
    }
    setState(() => _bootError = null);
    try {
      await _controller.retry();
    } on Object catch (error) {
      if (!mounted) {
        return;
      }
      setState(() => _bootError = error);
    }
  }

  void _retryResources() {
    if (!mounted) {
      return;
    }
    setState(() => _resourceError = null);
    unawaited(_loadResources());
  }

  @override
  void dispose() {
    // 解码后的封面像素是本 State 持有的 native 资源，必须自己放掉。
    _covers?.dispose();
    _covers = null;
    if (identical(QtSceneScrollRouter.instance.handler, _sceneScrollHandler)) {
      QtSceneScrollRouter.instance.handler = null;
    }
    if (_ownsController) {
      _controller.dispose();
    }
    if (_ownsAudio) {
      unawaited(_audio.dispose());
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 生产入口（lib/main.dart，commit 89493eb）目前仍是 flutter create 的计数器 demo：
    // BasicApp 还没有被任何生产调用点挂载（lib/ 里零引用，只有测试引用）。
    // 挂载由生产入口负责，本文件只交付这个组合根；
    // MaterialApp 由本 widget 提供，所以挂上去即可直接 runApp(const BasicApp())。
    // 主题跟着真实配色走（出厂默认亮色）：Flutter 控件层与 HUD 命令流不能一暗一亮。
    // MaterialApp 必须自己听 controller：设置页改配色时 BasicApp 不会因为
    // 子树的 ListenableBuilder 重建而重跑 build，否则 theme 会一直停在上一次的值。
    return ListenableBuilder(
      listenable: _controller,
      builder: (BuildContext context, Widget? _) {
        final bool dark = _controller.state.dark;
        return MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: ThemeData(
            brightness: dark ? Brightness.dark : Brightness.light,
            scaffoldBackgroundColor: dark ? Colors.black : const Color(0xFFEFEDE4),
          ),
          home: _home(),
        );
      },
    );
  }

  Widget _home() {
    final Object? bootError = _bootError;
    if (bootError != null) {
      return _BasicMessage(
        text: '$basicBootFailurePrefix$bootError',
        actionLabel: '重试',
        onAction: () => unawaited(_retryBoot()),
      );
    }
    final Object? resourceError = _resourceError;
    if (resourceError != null) {
      return _BasicMessage(
        text: '$basicResourceFailurePrefix$resourceError',
        actionLabel: '重试',
        onAction: _retryResources,
      );
    }
    final BasicHudResources? resources = _resources;
    if (resources == null) {
      return const _BasicMessage(text: basicResourceLoadingText);
    }
    if (resources.glyphs.weights.isEmpty) {
      // 字形表没有一条字重 = 没有可绘制的轮廓（Qt 这里是 fail hard，
      // 见 glyph_font.dart GlyphFontSet.empty 的说明 / Glyphs.cpp:28-33）。
      // failures 逐条留在这里，不做静默 fallback（basic_hud_resources.dart:35-36 的契约）。
      final List<String> failures = resources.failures;
      return _BasicMessage(
        text: basicGlyphMissingPrefix +
            (failures.isEmpty ? '字形表为空，且没有记录到失败项' : failures.join('\n')),
        actionLabel: '重试',
        onAction: _retryResources,
      );
    }
    return _BasicShell(
      controller: _controller,
      resources: resources,
      settingsStore: _settingsStore,
      playerPreferences: _playerPreferences,
      collections: _collections,
      bundle: widget.bundle,
    );
  }
}

/// 业务外壳：唯一 controller 的状态 → HUD 命令流。
///
/// 只做三件事：订阅 controller、按方向选舞台（横屏全窗口 / 竖屏 PortraitStage）、
/// 把命中动作转成 controller 调用。曲目选择、滚动、歌词等仍由 controller 与
/// 各 HUD 页面自己决定，本类不复制它们的状态。
class _BasicShell extends StatefulWidget {
  const _BasicShell({
    required this.controller,
    required this.resources,
    required this.settingsStore,
    required this.playerPreferences,
    required this.collections,
    this.bundle,
  });

  final BasicController controller;
  final BasicHudResources resources;

  /// 面板偏好的唯一存储（`panel/<key>`）。设置页写、启动读、效果读的都是它。
  final BasicSettingsStore settingsStore;

  /// 播放器的窄偏好（play-history / play-mode）同步镜像：偏好加载完成后由
  /// [_BasicShellState._loadSettings] 灌入，再回填播放模式。
  final BasicPlayerPreferences playerPreferences;

  /// 本机收藏（喜欢 / 自建歌单）的持久化实现，与 controller 共用同一实例。
  final LocalCollectionStore collections;

  /// 平台 descriptor 的 asset 源（测试注入；生产 null = rootBundle）。
  final AssetBundle? bundle;

  @override
  State<_BasicShell> createState() => _BasicShellState();
}

class _BasicShellState extends State<_BasicShell>
    // 两条 ticker：初始化动画（AnimationController）与封面查看器的场景时钟
    // （ViewerState.update 需要逐帧推进 transition/spring，见 lib/scene/viewer_state.dart:579）。
    // Qt 侧这两条时钟也是各自独立的（NativeScene 的 m_clock + NativeViewer 的 update）。
    with TickerProviderStateMixin
    implements TextInputPorts {
  /// 未接入动作的可见反馈（null = 无）。这里绝不静默吞点击，也不假装有设置/
  /// 账号功能：真实缺口写进可见反馈，并在报告里点名缺少的 controller 契约。
  ///
  /// 动作反馈与资源失败分两个槽：资源失败是**状态**（一直算数），动作反馈是
  /// **一次性提示**。同槽会让一次点击把“字体没装上”永久抹掉，那就又变成静默了。
  String? _actionNotice;

  /// 部分资源失败：[BasicHudResources.load] 从不抛错，字体/lettering 失败只进
  /// failures，字重表仍然非空——那种情况必须一直可见，不能被当成装载成功
  /// （basic_hud_resources.dart:35-36 的契约），也不能被动作反馈挤掉。
  String? _resourceNotice;

  /// 竖屏「歌曲操作」面板是否展开（Qt `m_songOptionsExpanded`，
  /// `mobile:song-options` 翻转；任何 `music:`/`tab:` 动作都会收起）。
  bool _songOptionsExpanded = false;

  /// 当前来源是否支持歌曲评论（Qt `commentsAvailable`）。siren 的 descriptor 里
  /// `operations.comments` 为 false ⇒ 面板里不会出现「查看评论」。
  bool get _commentsAvailable => false;

  /// 已装载的平台表（`display.order` 升序，见 [ProviderRegistry.ids]）。
  /// 装载完成前是空表：音乐平台页画空态，不伪造平台行。
  List<ProviderDescriptor> _providers = const <ProviderDescriptor>[];

  /// 当前平台 id（Qt `music.provider`）。缺省 siren，装载成功后换成
  /// 注册表的 `defaultId`（Qt `ProviderRegistry::defaultId`）。
  String _providerId = 'siren';

  /// 平台 id → 已恢复的账号（Qt `providerCardsState()` 的 authenticated 面）。
  /// 本预览没有账号恢复通道，恒为空表 ⇒ ACCOUNT 段一律「未登录」，不伪造登录态。
  final Map<String, ProviderAccount?> _providerAccounts = const <String, ProviderAccount?>{};

  /// 当前平台昵称（Qt `music.nickname`）。
  String get _providerUserName => _providerAccounts[_providerId]?.nickname ?? '';

  /// 当前弹层（'' = 无，'search' = 检索）。Qt 的 modal 由 NativeHud 自己持有
  /// （Qt/src/NativeHudController.cpp:64-130 openModal / :132-143 closeModal /
  /// :145-163 setQuery），BasicViewState 没有这个字段，也不在本文件的改动范围
  /// （basic_models.dart 不可改），所以它落在外壳里。
  ///
  /// 只有 '' 与 'search'：登录表单 / 歌单表单 / 设置编辑在本预览里没有入口
  /// （账号三平台暂停、设置页未接入），不伪造第三态。
  String _modal = '';

  /// 竖屏播放队列页的模式 chip 是否展开（Qt `m_queueModesExpanded`，由
  /// `mobile:queue-modes` 翻转；点任一 `player:mode:<x>` 后收起）。
  bool _queueModesExpanded = false;

  /// 横屏队列面板的首行下标（Qt `queueOffset`）。每次打开队列时重置为
  /// 「当前曲目置顶」（NativeHudController 的 openModal("player") 语义）。
  int _queueOffset = 0;

  /// 插件管理器（市场索引 / 安装 / 卸载 / 启用状态）。它是唯一真值来源：
  /// 页面只读 [PluginManager.snapshot]，动作回灌它的方法，不在外壳里存第二份。
  ///
  /// 目录来自 `pluginDir()`（`<pkg>/file/plugin`），与 Qt 的私有 `files/plugins`
  /// 不同——用户要求插件文件放在外部目录里能直接看到。
  late final PluginManager _plugins = PluginManager();

  /// 详情页正在看哪个插件（'' = 不在详情页）。列表页/详情页共用弹层栈：
  /// `_modal == 'plugins'` 是列表，`'plugin-detail'` 是详情。
  String _pluginDetailId = '';

  /// 面板偏好的唯一运行时（读/写/展开态/重启口径）。外壳持有一份，跨旋转不重建。
  late final BasicSettingsRuntime _settings;

  /// 初始化动画（Qt 的启动动效）。只在“初始化动画”偏好为 on 时跑，
  /// 或由“手动显示初始化动画”动作行显式重放（NativeHud 的 'replay'）。
  late final AnimationController _startup = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
    // 1.0 = 已播完：默认不盖黑幕，只有“初始化动画”开启或手动重放时才从 0 跑。
    value: 1,
  );
  /// 初始化页面是否正在显示（真实 boot 门槛页 + glyph 层，见 basic_startup_view.dart）。
  ///
  /// 与 [_startup] 分工：[_startup] 只是那一小段 1200ms 的交接淡出/舞台上移；
  /// 本开关代表"整页初始化界面在场"，由 boot 页自己的 35s 闸门或 ENTER SYSTEM 收起。
  bool _startupPageOpen = false;

  bool _startupEnabled = false;

  /// 封面查看器（Qt `NativeViewer`）在 Flutter 侧的镜像状态。
  ///
  /// 唯一真值仍是 Qt 的 NativeViewer（网格、相机、清晰度都在那边，Qt 侧不保存
  /// 第二份）；这里只镜像 HUD 需要的部分（transition/surface/clarity 弹簧），
  /// 用的就是 lib/scene/viewer_state.dart 这份逐字移植。null = 查看器没开。
  ViewerState? _coverViewer;

  /// 查看器场景时钟（秒），喂给 [ViewerState.update]；只在查看器期间推进。
  double _viewerTime = 0;
  Ticker? _viewerTicker;
  Duration? _viewerTickBase;

  /// 查看器命令的单调序号与当前命令（见 [BasicSceneSettings.viewerSeq]）。
  ///
  /// Flutter→Qt 只有 state/pointer/wheel 三条通道，命令只能贴快照下发；seq 递增
  /// 才能让 QtSceneView 判定"settings 变了"而真的推一份出去。
  int _viewerCommandSeq = 0;
  String _viewerCommand = '';

  /// 设置项“右侧画面遮罩”的强度真值（0..100）。出厂默认 0（关闭），
  /// 装载后取偏好值——偏好缺键时也是 0，不再是 Qt 的 50/55。
  double _archiveMaskStrength = 0;

  /// 竖屏唯一 [StageGeometry] 的引用（横屏不用）。
  ///
  /// 实例由 PortraitStage 在 Transform.scale 内部造（lib/ui/layout/portrait_stage.dart:34-150），
  /// 这里只【接管】同一实例，绝不自己调 computePortraitBands / withScale 再推一份
  /// （scale 只允许一个来源）。接管发生在首帧后，所以竖屏首帧不铺输入层。
  StageGeometry? _portraitGeometry;

  /// 场景层（Qt platform view）的身份键。
  ///
  /// 放在 App 状态里而不是 surface 里：横竖屏会换掉 surface 的父链
  /// （PortraitStage 的 Transform.scale ↔ 直挂 Stack），key 在更上层才能在
  /// 旋转时把同一个 PlatformView element 移动过去，而不是销毁重建 QQuickView
  /// （重建 = 场景/Node/播放全断，用户报的"一转屏就重启"）。
  final GlobalKey _sceneKey = GlobalKey(debugLabel: 'basic-qt-scene');

  /// HUD 输入层的焦点节点。
  ///
  /// Qt 的隐藏输入框把焦点交回 QML 的 inputLayer（Overlay.qml:546
  /// inputLayer.forceActiveFocus()）；本外壳对应为 HUD 子树的这个节点，
  /// 关框后由 [focusInputLayer] 收回，避免「没有任何节点持焦点」导致
  /// 硬件键盘/遥控器导航断掉。
  final FocusNode _hudFocusNode = FocusNode(debugLabel: 'basic-hud-input-layer');

  /// NativeHud::key 的两个成员：Qt 里 settingsScroll / desktopLyricsScroll 是
  /// NativeHud 的成员变量（Qt/src/NativeHudController.cpp:891-904 就地修改），这里同形。
  ///
  /// settingsScroll 不另存一份真值：每次分派前从 [_settingsScroll]（真实
  /// ScrollController 的存储）拷进来、分派后写回去，避免「键改的是死变量」。
  final HudScrollOffsets _keyScrollOffsets = HudScrollOffsets();

  /// 设置卡片当前的真实可滚动距离（由 BasicSettingsWindow 排完版后公布）。
  ///
  /// NativeHudController.cpp:891-897 的 clamp 上界是 contentBottom - settingsViewportTop；
  /// 这里用真实 maxScrollExtent 反推，而不是写死 1600。
  final ValueNotifier<double> _settingsScrollMaximum = ValueNotifier<double>(0);

  /// Engine.cpp:952-1012 的 keyEvent 层：媒体键 → 翻译键 → event.text → key(value)。
  late final EngineKeyRouter _engineKeyRouter =
      EngineKeyRouter(ports: _BasicEngineKeyPorts(this));

  /// NativeHud::key（Qt/src/NativeHudController.cpp:887-943）的 1:1 路由。
  ///
  /// 之前这个外壳**没有**键盘入口：HUD 根节点只有 Force 焦点，没有 onKeyEvent，
  /// 于是 Overlay.qml:118-120（`Keys.onPressed` → `rhine.keyEvent`）在 Flutter 侧
  /// 整层缺失——用户看得到 HUD 底部「←→ 切换来源 / ↑↓ 选曲 / ENTER 查看 / 检索」的
  /// 提示，按下去却没有动作。补的就是这一层：键 → [HudKeyRouter] → 既有 [_onAction]。
  late final HudKeyRouter _keyRouter =
      HudKeyRouter(ports: _BasicHudKeyPorts(this));

  BasicController get controller => widget.controller;

  @override
  void initState() {
    super.initState();
    _resourceNotice = _resourceFailuresNotice(widget.resources);
    _settings = BasicSettingsRuntime(store: widget.settingsStore);
    _startup.addStatusListener(_onStartupStatus);
    // 插件：解析目录 + 扫已装插件（不读市场，市场要用户点「刷新市场」才拉——
    // 与 Qt 相同：openModal 之后才 refreshPluginMarketplace）。
    _plugins.addListener(_onPluginsChanged);
    unawaited(_plugins.initialize());
    unawaited(_loadSettings());
    // 收藏落盘读取与曲库并行：控制器要的是「已装载的 liked 集合」，所以先读
    // 盘再 refresh（后者在曲库装载后还会再跑一次，见 _refreshLocalCollections）。
    unawaited(_loadCollections());
    // 平台表（音乐平台页的数据真值）：与曲库并行装载，失败只进动作槽。
    unawaited(_loadProviders());
    // Overlay.qml:541-548：输入框隐藏时 inputLayer.forceActiveFocus()。Qt 在启动
    // 完成时就把焦点交给 HUD 输入层；这里晚一帧做同一件事，否则硬件键盘没有任何
    // 节点接收——设备上「ENTER 查看 / 方向键」会全部静默（161 补的键盘入口要靠它）。
    WidgetsBinding.instance.addPostFrameCallback((Duration _) {
      if (mounted && _modal.isEmpty) {
        focusInputLayer();
      }
    });
  }

  /// 读取本机收藏（喜欢 / 自建歌单）。失败不阻断启动：没有收藏存储时
  /// 控制器会说「本地收藏尚未接入」，列表退回空态而不是整页报错。
  Future<void> _loadCollections() async {
    try {
      await widget.collections.load();
    } on Object catch (error) {
      if (!mounted) {
        return;
      }
      setState(() => _actionNotice = '本机收藏读取失败：$error');
      return;
    }
    if (!mounted) {
      return;
    }
    controller.refreshLocalCollections();
  }

  /// 读取内置平台 descriptor 并装成注册表（音乐平台页的数据真值）。
  ///
  /// 顺序与 `ProviderAssetLoader.load` 一致：读 assets → `ProviderRegistry.load`。
  /// 失败不阻断启动：平台页退回空表（画空态），原因进动作槽。
  Future<void> _loadProviders() async {
    final ProviderAssetLoader loader = ProviderAssetLoader(bundle: widget.bundle);
    try {
      final List<Map<String, Object?>> builtins = await loader.readBuiltins();
      final ProviderRegistry registry = ProviderRegistry.load(builtins: builtins);
      if (!mounted) {
        return;
      }
      setState(() {
        _providers = <ProviderDescriptor>[
          for (final String id in registry.ids)
            if (registry.descriptor(id) != null) registry.descriptor(id)!,
        ];
        final String defaultId = registry.defaultId ?? '';
        _providerId = defaultId.isNotEmpty ? defaultId : 'siren';
      });
    } on Object catch (error) {
      if (!mounted) {
        return;
      }
      setState(() => _actionNotice = '读取平台列表失败：$error');
    }
  }

  void _onStartupStatus(AnimationStatus status) {
    if (status == AnimationStatus.completed || status == AnimationStatus.dismissed) {
      if (mounted) {
        setState(() {});
      }
    }
  }

  /// 装载真值：读完偏好后把**真实生效**的效果接到 controller / 场景上。
  ///
  /// 这条链是"持久化 -> 效果"的唯一入口，因此重启 App 后配色、自动播放、
  /// 单曲播放语义、画面遮罩都从这里恢复，不是只记住开关样子。
  Future<void> _loadSettings() async {
    try {
      await _settings.load();
    } on Object {
      // 读偏好失败不阻断启动：运行时自己退到默认值，面板照常可打开。
    }
    // 播放器的窄偏好与设置页共用 `panel/` 键空间：先把已存值灌进同步镜像，
    // 再让播放器按白名单回填模式（play-history 的 JSON 历史同理）。
    widget.playerPreferences.seed(_settings.raw);
    controller.resyncPreferences();
    if (!mounted) {
      return;
    }
    _applySettingsEffects(replayStartup: true);
    // 首启把空偏好补成 "off"（Qt/src/NativeApplication.cpp:69-71）：本次已经播了 boot，
    // 之后开屏不再强制显示，直到用户自己在设置里打开。
    unawaited(_settings.settleFirstLaunchStartupPreference());
    setState(() {});
  }

  void _applySettingsEffects({bool replayStartup = false}) {
    controller.setDark(_settings.dark);
    controller.setDetailAutoplay(_settings.detailAutoplay);
    controller.setSinglePlayAppend(_settings.singlePlayAppend);
    _archiveMaskStrength = _settings.archiveMaskStrength.toDouble();
    // Qt/src/NativeApplication.cpp:62-71：首启（偏好为空）也会播一次 boot，之后
    // 才把空偏好补成 "off"；用户显式关掉之后不再强制开屏。
    _startupEnabled =
        _settings.startupAnimation || _settings.startupAnimationNeverConfigured;
    if (replayStartup && _startupEnabled) {
      _replayStartup();
    }
  }

  /// 重新进入 boot：显示真实初始化页面（Qt 的 `hud.action("replay")`，
  /// NativeHudController.cpp:698 → `m_scene.mode("boot")`）。
  void _replayStartup() {
    if (!mounted) {
      return;
    }
    _startup.value = 0;
    _startupPageOpen = true;
    setState(() {});
  }

  /// 初始化页面交割（35s 到点，或用户点 ENTER SYSTEM / 跳过）：收起整页，
  /// 然后播那一小段舞台上升淡出（保留原有 1200ms 手感，作为 boot 页退出后的落位）。
  void _finishStartupPage() {
    if (!_startupPageOpen) {
      return;
    }
    setState(() => _startupPageOpen = false);
    if (_startupEnabled) {
      _startup.forward(from: 0);
    } else {
      // 手动重放（偏好本来是关的）也要把幕布收干净：_startup.value 停在 0 且没有
      // 动画在跑时，[_startupCurtain] 会按 t=0 画一整块黑幕，界面就再也回不来了。
      _startup.value = 1;
    }
  }

  // ── 封面查看器（req3：详情页「查看封面 ↗」的真实归属）──────────────────────────

  /// 打开查看器：真实选中条目的封面/展厅由 Qt 的 NativeViewer 渲染
  /// （NativeSceneInput.cpp:241-243 openViewer），Flutter 只负责命令与 HUD。
  ///
  /// `resumeMode` 记的是打开时的场景模式：关掉后回到先前那个相位（详情/资料库），
  /// 选中、滚动、队列一概不动（本方法不碰 controller）。
  void _openCoverViewer() {
    if (_coverViewer != null) {
      return;
    }
    final ViewerState viewer = ViewerState(resumeMode: qtSceneModeOf(controller.state));
    // ready 在 Flutter 侧只能是"HUD 按 Qt 版式画全"的意思：Qt 的 m_ready 取决于
    // archive-assembly.json 网格是否装载成功（NativeViewer::open 里 m_ready = !m_meshes.isEmpty()），
    // 而 Flutter→Qt 只有 state/pointer/wheel 三条单向通道，拿不到这个布尔值。
    // 真正的门禁仍在 Qt：viewerAction 在 !m_ready 时直接返回（NativeViewer.cpp:108-120），
    // 所以网格缺失时按 clear/frosted/reset 只是这里高亮、Qt 不动，不会画出假状态。
    viewer.open(_viewerTime, ready: true);
    _coverViewer = viewer;
    _sendCoverViewerCommand('open');
    _viewerTicker ??= createTicker(_onViewerTick);
    _viewerTickBase = null;
    if (!_viewerTicker!.isActive) {
      _viewerTicker!.start();
    }
    setState(() {});
  }

  /// 关闭查看器：先走 NativeViewer 的 close 语义（transition=closing，0.22s 后
  /// 真正落地），动画结束由 [_onViewerTick] 收尾。Qt 侧同一份状态自己也在跑。
  void _requestCloseCoverViewer() {
    final ViewerState? viewer = _coverViewer;
    if (viewer == null || viewer.isClosing) {
      return;
    }
    viewer.act(ViewerAction.close, _viewerTime);
    _sendCoverViewerCommand('close');
    setState(() {});
  }

  void _finishCoverViewer() {
    _viewerTicker?.stop();
    _viewerTickBase = null;
    if (!mounted) {
      return;
    }
    setState(() => _coverViewer = null);
  }

  /// 逐帧推进查看器时钟（Qt NativeViewer::update 的对应物）。
  void _onViewerTick(Duration elapsed) {
    final ViewerState? viewer = _coverViewer;
    if (viewer == null) {
      return;
    }
    final Duration? base = _viewerTickBase;
    _viewerTickBase = elapsed;
    if (base != null) {
      final double delta =
          (elapsed - base).inMicroseconds / Duration.microsecondsPerSecond;
      if (delta > 0) {
        _viewerTime += delta;
      }
    }
    final ViewerCloseOutcome? outcome = viewer.update(_viewerTime);
    if (outcome != null) {
      _finishCoverViewer();
      return;
    }
    // 只有还在过渡/弹簧未收敛时才重建：查看器完全打开后 HUD 是静止的，
    // 每帧 setState 会把整个外壳（含 PlatformView 的父链）都刷一遍，白耗。
    final bool animating = viewer.isClosing ||
        viewer.transition != ViewerTransition.open ||
        viewer.resetting ||
        (viewer.clarity - viewer.targetClarity).abs() > 0.001 ||
        (viewer.spread - viewer.targetSpread).abs() > 0.001;
    if (animating) {
      setState(() {});
    }
  }

  /// 下一条查看器命令（seq 单调，Qt 侧按 seq 去重后执行一次）。
  void _sendCoverViewerCommand(String action) {
    _viewerCommandSeq += 1;
    _viewerCommand = action;
    if (mounted) {
      setState(() {});
    }
  }

  /// 查看器 HUD 的命中断言：Qt 的 viewer 页只有 6 个按钮，动作语义逐条对应
  /// NativeHudController.cpp 的路由（'music:cover-front' 走 coverFront，其余走
  /// NativeViewer::action）。HUD 的命中串本身就是动作串，这里不再造第二套。
  void _onCoverViewerAction(String action) {
    final ViewerState? viewer = _coverViewer;
    if (viewer == null) {
      return;
    }
    if (action == 'viewer:close') {
      _requestCloseCoverViewer();
      return;
    }
    if (action == 'music:cover-front') {
      // NativeViewer::coverFront 没有 m_open / m_ready 门禁（NativeViewer.cpp:99-107）。
      _sendCoverViewerCommand('cover-front');
      return;
    }
    final ViewerAction? parsed = ViewerAction.fromWire(action.replaceFirst('viewer:', ''));
    if (parsed == null) {
      return;
    }
    // 本地镜像与 Qt 走同一份仲裁：ready/closing 时 Qt 也会忽略，两边不会各说各话。
    viewer.act(parsed, _viewerTime);
    _sendCoverViewerCommand(parsed.wire);
    setState(() {});
  }

  /// 查看器 HUD 状态：条目取**当前选中曲目**（其次专辑）——与 Qt 读 m_music->current
  /// 同一份真值；没有选中就传 null，viewer 页按 NativeHudDetail.cpp:514-516 早退。
  ViewerHudState _viewerHudState(BasicViewState state, ViewerState viewer) {
    final SirenSong? song = state.song;
    if (song != null) {
      return basicViewerHudState(
        viewer: viewer,
        dark: state.dark,
        id: song.id,
        title: song.title,
      );
    }
    final SirenAlbum? album = state.album;
    return basicViewerHudState(
      viewer: viewer,
      dark: state.dark,
      id: album?.id,
      title: album?.name,
    );
  }

  @override
  void dispose() {
    _viewerTicker?.dispose();
    _startup.dispose();
    _hudFocusNode.dispose();
    // 面板滚动偏移是本次运行内跨开关复用的 notifier；State 自己持有，自己负责关掉。
    _settingsScroll.dispose();
    _settingsScrollMaximum.dispose();
    _plugins.removeListener(_onPluginsChanged);
    _plugins.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant _BasicShell oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 重试装载会换一份 resources：失败项跟着换，不能让旧横幅留在屏幕上。
    if (!identical(oldWidget.resources, widget.resources)) {
      _resourceNotice = _resourceFailuresNotice(widget.resources);
    }
  }

  /// 部分失败 → 可见文案；零失败 → null（正常不出横幅）。
  ///
  /// 前 [maxShown] 项逐条列出，其余只报总数：横幅是提示，不是日志页，
  /// 但也不许把失败数藏起来（总数照报）。
  static String? _resourceFailuresNotice(BasicHudResources resources) {
    const int maxShown = 4;
    final List<String> failures = resources.failures;
    if (failures.isEmpty) {
      return null;
    }
    final String head = failures.take(maxShown).join('；');
    final String more =
        failures.length > maxShown ? '；…共 ${failures.length} 项' : '';
    return basicResourceFailurePrefix + head + more;
  }

  @override
  Widget build(BuildContext context) {
    final String? actionNotice = _actionNotice;
    final String? resourceNotice = _resourceNotice;
    return Scaffold(
      backgroundColor: Colors.black,
      // 输入法不避让（真人要求 m01988）：弹出键盘不许把舞台/3D 视图顶上去，
      // 也不许缩窗。Manifest 的 windowSoftInputMode 同步是 adjustNothing，
      // 两侧一致才不会出现"Flutter 留白 + 原生窗口被压缩"的混搭。
      resizeToAvoidBottomInset: false,
      body: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          LayoutBuilder(
            builder: (BuildContext context, BoxConstraints constraints) {
              final double width = constraints.maxWidth;
              final double height = constraints.maxHeight;
              if (!(width > 0) || !(height > 0)) {
                return const ColoredBox(color: Colors.black);
              }
              final bool portrait =
                  classifyOrientation(logicalWidth: width, logicalHeight: height) ==
                      OrientationKind.portrait;
              return ListenableBuilder(
                listenable: controller,
                builder: (BuildContext context, Widget? child) {
                  final BasicViewState state = controller.state;
                  // 横屏：几何体每帧现造一份，绘制 / 命中 / 输入层共用这一个实例。
                  final StageGeometry? landscape = portrait
                      ? null
                      : StageGeometry.landscape(logicalWidth: width, logicalHeight: height);
                  final Widget surface;
                  if (portrait) {
                    // 竖屏由 PortraitStage 注入唯一的 StageGeometry/HudStage 作用域；
                    // 输入层必须挂在窗口级（见 _textInput），所以这里只接管那份引用。
                    surface = _popScope(
                      state,
                      PortraitStage(
                        child: Builder(
                          builder: (BuildContext inner) {
                            _adoptPortraitGeometry(StageGeometryScope.of(inner));
                            return _surface(state);
                          },
                        ),
                      ),
                    );
                  } else {
                    // 横屏沿用 Qt 全窗口高（Main.qml:32），几何与命中读同一份。
                    surface = _popScope(
                      state,
                      _surface(
                        state,
                        geometry: landscape,
                        stage: HudStage.fromLogicalSize(width: width, height: height),
                      ),
                    );
                  }
                  final Widget? input = _textInput(
                    state,
                    geometry: portrait ? _portraitGeometry : landscape,
                    portrait: portrait,
                  );
                  return Stack(
                    fit: StackFit.expand,
                    children: <Widget>[
                      // HUD 子树持一个焦点节点：输入层收起时焦点回到这里
                      // （Overlay.qml:546 inputLayer.forceActiveFocus 的对应物）。
                      // 语义仍由 HUD 自己的 a11y 层产出（lib/hud/a11y），这里不加语义节点，
                      // 免得给 HUD 根多插一层 focusable 打断既有语义树。
                      Focus(
                        focusNode: _hudFocusNode,
                        includeSemantics: false,
                        onKeyEvent: _onHudKeyEvent,
                        child: surface,
                      ),
                      if (input != null) Positioned.fill(child: input),
                    ],
                  );
                },
              );
            },
          ),
          if (actionNotice != null || resourceNotice != null)
            Positioned(
              left: 0,
              right: 0,
              // 贴在播放条（品牌头 + 播放行）之上，不盖住播放控件。
              bottom: playerBarHeaderHeight + playerBarRowHeight + 8,
              // 反馈条不吃命中：HUD 的热区照旧按原坐标工作。
              child: IgnorePointer(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    if (actionNotice != null) _BasicNotice(text: actionNotice),
                    if (resourceNotice != null) _BasicNotice(text: resourceNotice),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _surface(BasicViewState state, {StageGeometry? geometry, HudStage? stage}) {
    // 封面查看器开着：Qt 侧只画 viewer 页（NativeHud.cpp:267-268），详情页的 HUD
    // 不能再画一份，所以整屏换成查看器那一支。3D 场景层仍是同一个 PlatformView
    // （_sceneKey 不变 → element 被移动而非重建，QQuickView 不重启）。
    final ViewerState? coverViewer = _coverViewer;
    if (coverViewer != null) {
      return _coverViewerSurface(state, coverViewer, geometry: geometry, stage: stage);
    }
    final Widget hud = BasicHudSurface(
      state: state,
      ports: widget.resources.ports,
      onAction: _onAction,
      // 场景层的身份键在 App 状态里（不在 surface 里）：横竖屏会换掉 surface 的
      // 父链（PortraitStage ↔ 直挂 Stack），只有把 key 抬到上层，PlatformView 的
      // element 才能被移动而非重建。
      sceneKey: _sceneKey,
      // 渲染参数投影：disc/mask 逐帧生效；渲染分辨率、AA 模式/倍率、MSAA、超采样
      // 在 Android 上是"写进 Qt 的 panel/* 偏好 + 当场 qputenv"，渲染器每帧读环境变量、
      // 下一帧就重建目标（Qt/src/EmbeddedSceneHost.cpp 设置块）；只有图形后端与
      // 垂直同步仍要下次进程启动（main.cpp 里在 main() 决定）。
      sceneSettings: _sceneSettings(),
      // 曲目列手指拖动的落点（条目单位）：只**选中**落到的那一项，
      // 不播放、不换队列（Qt/src/MusicLibrary.cpp:616-643 open=false 的选中语义）。
      // 拖动过程的插值在 surface 内部完成，这里只接结束时的那一次提交。
      onLibraryScroll: (double position) =>
          unawaited(controller.commitLibraryScroll(position)),
      // 用户 P0 #1 的列表→3D 那半：拖动**中途**每次位置变化都推进同一个窗口真值，
      // snapshot 的 pos 因此每帧变化，Qt 侧 projectArchiveScroll 让原 3D 窗口跟着滚，
      // 不必等松手（松手仍由 onLibraryScroll 落行选中）。
      onLibraryScrollUpdate: controller.updateLibraryScroll,
      geometry: geometry,
      stage: stage,
      archiveMaskStrength: _archiveMaskStrength,
      // 竖屏排版按弹层选页（检索页/设置/插件/播放队列）；横屏只有 'queue'
      // 会在同一帧里叠一层队列面板。
      modal: _modal,
      // 队列面板的首行下标与竖屏滚动量：只有打开队列时才看这两项，
      // 其它弹层下 HUD 不会读它们，所以不必逐帧清空。
      queueOffset: _queueOffset,
      queueModesExpanded: _queueModesExpanded,
      // 插件页的数据快照与详情（HUD 只画 chrome，内容在 widget 层）。
      plugins: _plugins.snapshot(),
      pluginDetail: _pluginDetailManifest(),
      pluginDetailEnabled: _pluginDetailEnabled,
      pluginDetailUserInstalled: _pluginDetailUserInstalled,
      pluginDetailCanRollback: _pluginDetailCanRollback,
      pluginMessage: _plugins.snapshot().message,
      // 竖屏详情/歌词页的「歌曲操作」面板（Qt `m_songOptionsExpanded`）。
      songOptionsExpanded: _songOptionsExpanded,
      // Qt `commentsAvailable = !isLocal() && !CommentsController::commentsProvider(provider).isEmpty()`；
      // siren 的 descriptor 里 `operations.comments` 为 false，所以失败时这里恒 false，
      // 面板不会画出一个点了没反应的「查看评论」。
      commentsAvailable: _commentsAvailable,
      songOptionsDetail: _songOptionsDetail(state),
      songOptionsDetailBody: _songOptionsDetailBody(state),
      // 音乐平台页（modal == 'provider'）的数据真值。
      providers: _providers,
      providerId: _providerId,
      providerAccounts: _providerAccounts,
      providerUserName: _providerUserName,
    );
    final bool settingsOpen =
        _modal == 'settings' || _modal == DiscWarningModal.kind;
    // 插件列表页/详情页与设置页同构：chrome 由 HUD 画，内容是真 widget 层，
    // 所以这里要把它们一起纳入「需要叠 widget 层」的判断（否则只有 HUD 页头）。
    //
    // 但**歌曲页/歌词页在 HUD 里优先级高于弹层**（basic_hud.dart 的 `songPage`
    // 分支先于 `modal == 'plugins'`）：在插件页点底部播放条会把 phase 切成 lyrics，
    // HUD 立刻画歌词页，而 widget 层若还按 modal 判断就会继续画插件页 ⇒ 两页重叠。
    // 所以 widget 层必须跟 HUD 用同一个前提：只有 HUD 真的在画插件页时才叠。
    final bool hudPaintsSongPage = state.song != null &&
        (state.phase == BasicPhase.detail || state.phase == BasicPhase.lyrics);
    final bool pluginsOpen =
        !hudPaintsSongPage && (_modal == 'plugins' || _modal == 'plugin-detail');
    final bool startupOpen = _startupPageOpen;
    // 初始化页面在场时不再叠黑幕：那时整页 boot HUD 自己就是画面
    // （NativeHudBoot::boot 的 gradient/flash 门槛层），底下留真实场景当背景。
    final bool animating = !startupOpen && _startup.isAnimating;
    if (!settingsOpen && !pluginsOpen && !startupOpen && !animating) {
      return hud;
    }
    final double scale = stage?.scale ?? 1.0;
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        if (startupOpen)
          Builder(
            builder: (BuildContext inner) => _sceneOnly(
              state,
              geometry: geometry,
              stage: stage ?? HudStageScope.of(inner),
            ),
          )
        else
          _startupCurtain(hud, scale: scale),
        if (startupOpen)
          Positioned.fill(
            child: Builder(
              builder: (BuildContext inner) {
                final HudStage resolved = stage ?? HudStageScope.of(inner);
                final double pageScale = resolved.scale > 0 ? resolved.scale : 1.0;
                // 初始化页整套坐标是 Qt 舞台坐标（1920 设计宽 / 1080 高，见
                // boot_page.dart:1119 的约定）：门槛层命令与 ENTER SYSTEM 按钮都是
                // stage 单位。logical→stage 的这一次缩放由宿主给，页内不再二次换算。
                //
                // 但 Positioned.fill 给的是 logical 紧约束：直接套 Transform 时
                // RenderConstrainedBox 会用 `additionalConstraints.enforce(parent)`
                // 把 SizedBox 声明的 stage 尺寸压回 logical（2880x1800 / dpr≈2.3625 →
                // 1219x762），子树按 logical 布局后再被 Transform.scale(0.70556) 缩一次，
                // 画面只剩左上 1219*0.70556 ≈ 860 logical（= 2032 物理，70.5%）。
                // OverflowBox 放开紧约束，让 stage 子树真实按 stage 尺寸（1728x1080）
                // 布局，缩放只发生这一次（同 basic_settings_window.dart:176-199）。
                // stage.scale == 1 时（竖屏 PortraitStage 的 stageHeight 舞台 / 1080 高窗口）
                // min/max 与父级紧约束完全一致，是零差异的 no-op。
                return ClipRect(
                  child: OverflowBox(
                    alignment: Alignment.topLeft,
                    minWidth: resolved.width,
                    maxWidth: resolved.width,
                    minHeight: resolved.height,
                    maxHeight: resolved.height,
                    child: Transform.scale(
                      scale: pageScale,
                      alignment: Alignment.topLeft,
                      child: SizedBox(
                        width: resolved.width,
                        height: resolved.height,
                        child: BasicStartupView(
                          ports: widget.resources.ports,
                          dark: state.dark,
                          onHandoff: _finishStartupPage,
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        if (settingsOpen)
          Builder(
            builder: (BuildContext inner) {
              final HudStage resolved = stage ?? HudStageScope.of(inner);
              return Stack(
                fit: StackFit.expand,
                children: <Widget>[
                  // m03428：设置窗口是真实 Flutter widget 层（文本/控件/滚动/
                  // 焦点/语义都是 widget），不再走 HUD 命令 + 命中画布。
                  //
                  // 竖屏用 BasicPortraitSettingsPage：那套几何是 393 设计网格的
                  // compact 版式（Qt ResponsiveHudLayout::settings()）。横屏面板的
                  // 绝对坐标（viewportTop=176/height=660、controlWidth=300）是为
                  // 1080 舞台 + 1260 面板设计的，竖屏整体放大后控件会压住标题。
                  if (geometry == null)
                    Align(
                      alignment: Alignment.topLeft,
                      child: BasicPortraitSettingsPage(
                        stage: resolved,
                        // 与竖屏画布同一口径：PortraitBands 的 stageScale = 逻辑宽/1080。
                        stageScale: MediaQuery.sizeOf(inner).width /
                            HudScale.designStageHeight,
                        model: _settingsPanelModel(),
                        dark: state.dark,
                        scrollStorage: _settingsScroll,
                        scrollMaximumStorage: _settingsScrollMaximum,
                        onAction: (String action) =>
                            unawaited(_onSettingsAction(action)),
                      ),
                    )
                  else
                    BasicSettingsWindow(
                      stage: resolved,
                      portrait: false,
                      // 横屏设置末尾补「插件管理」入口（竖屏设置页末尾那张同义卡）。
                      pluginsEntry: true,
                      model: _settingsPanelModel(),
                      dark: state.dark,
                      scrollStorage: _settingsScroll,
                      scrollMaximumStorage: _settingsScrollMaximum,
                      onAction: (String action) =>
                          unawaited(_onSettingsAction(action)),
                    ),
                  if (_modal == DiscWarningModal.kind)
                    BasicDiscWarningOverlay(
                      stage: resolved,
                      ports: widget.resources.ports,
                      dark: state.dark,
                      onAction: (String action) =>
                          unawaited(_onSettingsAction(action)),
                    ),
                ],
              );
            },
          ),
        // 插件列表页 / 详情页：与设置页同构（竖屏 HUD 画纸色 + 通用页头 + 播放条 + 底栏；
        // 横屏由页面自己画遮罩 + modalBounds 面板）。竖屏页面按 393 网格 +
        // Transform.scale(unit) 排版，只对齐左上角；横屏页面按舞台坐标排版并自带缩放。
        if (pluginsOpen)
          Builder(
            builder: (BuildContext inner) {
              final HudStage resolved = stage ?? HudStageScope.of(inner);
              final bool landscape = geometry != null;
              // 与竖屏画布同一口径：PortraitBands 的 stageScale = 逻辑宽/1080。
              final double stageScale =
                  MediaQuery.sizeOf(inner).width / HudScale.designStageHeight;
              final PluginSnapshot snapshot = _plugins.snapshot();
              final PluginManifest? detail = _pluginDetailManifest();
              void onAction(String action) {
                // 横屏页自己的返回键发 settings / close-modal；这两个都是弹层
                // 开关，走 _onAction（settings 回设置面板、close-modal 回主界面），
                // 不进 plugin:* 处理器。
                if (action == HudAction.closeModal || action == 'settings') {
                  _onAction(action);
                  return;
                }
                unawaited(_onPluginAction(action));
              }
              final Widget page;
              if (_modal == 'plugin-detail' && detail != null) {
                page = landscape
                    ? BasicLandscapePluginDetailPage(
                        stage: resolved,
                        plugin: detail,
                        enabled: _pluginDetailEnabled,
                        userInstalled: _pluginDetailUserInstalled,
                        canRollback: _pluginDetailCanRollback,
                        pendingUninstall: _pendingPluginUninstall,
                        dark: state.dark,
                        message: snapshot.message,
                        onAction: onAction,
                      )
                    : BasicPortraitPluginDetailPage(
                        stage: resolved,
                        plugin: detail,
                        enabled: _pluginDetailEnabled,
                        userInstalled: _pluginDetailUserInstalled,
                        // `.backup-<id>` 存在才可回滚（Qt 重装/升级后才有）。
                        canRollback: _pluginDetailCanRollback,
                        pendingUninstall: _pendingPluginUninstall,
                        dark: state.dark,
                        stageScale: stageScale,
                        message: snapshot.message,
                        onAction: onAction,
                      );
              } else {
                page = landscape
                    ? BasicLandscapePluginsPage(
                        stage: resolved,
                        snapshot: snapshot,
                        dark: state.dark,
                        pendingUninstall: _pendingPluginUninstall,
                        installing: snapshot.progress.installing,
                        installLabel: snapshot.progress.id,
                        onAction: onAction,
                      )
                    : BasicPortraitPluginsPage(
                        stage: resolved,
                        snapshot: snapshot,
                        dark: state.dark,
                        pendingUninstall: _pendingPluginUninstall,
                        stageScale: stageScale,
                        // 进度条与「安装中…」按钮都靠这两个字段（之前没传，
                        // 真机上只看得到状态行、看不到进度）。
                        installing: snapshot.progress.installing,
                        installLabel: snapshot.progress.id,
                        onAction: onAction,
                      );
              }
              return landscape
                  ? page
                  : Align(alignment: Alignment.topLeft, child: page);
            },
          ),
      ],
    );
  }

  /// 只有 3D 场景层，没有 HUD。
  ///
  /// 初始化页面在场时就是这个形态：Qt 的 boot 相位里 scene 在自己的时间轴上画
  /// boot 视觉，HUD 整块交给 NativeHudBoot（NativeHud.cpp:267-268 的 boot 分支
  /// 不画 brand/导航/曲目列/播放条）。若这里仍把详情 HUD 垫在底下，boot 页在
  /// 26.92s 淡出（backgroundOpacity→0）之后就会露出详情页——Qt 不会。
  Widget _sceneOnly(
    BasicViewState state, {
    required StageGeometry? geometry,
    required HudStage stage,
  }) {
    final StageGeometry? landscape = geometry;
    final Rect? sceneStage = basicSceneStageRect(
      portrait: landscape == null,
      width: stage.width,
      height: stage.height,
    );
    if (sceneStage == null) {
      return const SizedBox.expand();
    }
    // 竖屏子树已经在 stage 坐标里，横屏才要 logical→stage（与 BasicHudSurface 同式）。
    final Rect rawSceneRect =
        landscape == null ? sceneStage : landscape.rectToLogical(sceneStage);
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        Positioned.fromRect(
          rect: rawSceneRect,
          child: QtSceneView(
            key: _sceneKey,
            state: state,
            settings: _sceneSettings(),
            onAction: _onAction,
          ),
        ),
      ],
    );
  }

  /// 查看器那一支的舞台：3D 场景层（同一个 PlatformView）+ 查看器 HUD。
  ///
  /// 为什么不复用 [BasicHudSurface]：它会画详情/资料库的整页 HUD（brand、导航、
  /// 曲目列、播放条），而 Qt 的 viewer 页把这些全部让给查看器
  /// （NativeHud.cpp:267-268 只调 viewer()，:306-311 只补 modal 与播放条）。
  /// 这里也不去改 basic_hud.dart（source_A 的改动范围），免得两路同时改同一个文件。
  Widget _coverViewerSurface(
    BasicViewState state,
    ViewerState viewer, {
    StageGeometry? geometry,
    HudStage? stage,
  }) {
    return Builder(
      builder: (BuildContext inner) {
        final HudStage resolved = stage ?? HudStageScope.of(inner);
        final StageGeometry? landscape = geometry;
        final bool portrait = landscape == null;
        // 与 BasicHudSurface 同一份几何真值（basic_hud.dart:409-427）：横屏铺满整窗、
        // 竖屏铺到列表起点之上。查看器的相机视口就是这块，改它等于改 fov。
        final Rect? sceneStage = basicSceneStageRect(
          portrait: portrait,
          width: resolved.width,
          height: resolved.height,
        );
        final Rect? rawSceneRect = (sceneStage == null || landscape == null)
            ? sceneStage
            : landscape.rectToLogical(sceneStage);
        final Widget viewerHud = BasicCoverViewerOverlay(
          stage: resolved,
          ports: widget.resources.ports,
          state: _viewerHudState(state, viewer),
          onAction: _onCoverViewerAction,
        );
        return Stack(
          fit: StackFit.expand,
          children: <Widget>[
            if (rawSceneRect != null)
              Positioned.fromRect(
                rect: rawSceneRect,
                child: QtSceneView(
                  key: _sceneKey,
                  state: state,
                  settings: _sceneSettings(),
                  onAction: _onAction,
                ),
              ),
            // 查看器 HUD 盖在场景上；指针同时照旧搬给 Qt（旋转/平移/双指缩放都在
            // NativeViewer::pointer 里），HUD 只有 6 个按钮，点一下同时到达两边
            // 也只是一次没有位移的 down/up，Qt 看不到拖动——不设 ownership 判据
            // 反而不会出现"点在按钮上时场景不动、拖动时按钮又吃掉"的半吊子状态。
            if (rawSceneRect != null)
              Positioned.fill(
                child: QtSceneRawPointerLayer(
                  sceneRect: rawSceneRect,
                  child: viewerHud,
                ),
              )
            else
              Positioned.fill(child: viewerHud),
          ],
        );
      },
    );
  }

  /// 初始化动画：黑色幕布淡出 + 舞台轻微上升（1200ms，ease-out）。
  ///
  /// 只在运转时包一层；静止后原样返回 [child]，不额外留一个恒等变换。
  Widget _startupCurtain(Widget child, {required double scale}) {
    if (!_startup.isAnimating && _startup.value >= 1) {
      return child;
    }
    return AnimatedBuilder(
      animation: _startup,
      child: child,
      builder: (BuildContext context, Widget? inner) {
        final double t = Curves.easeOutCubic.transform(_startup.value.clamp(0.0, 1.0));
        return Stack(
          fit: StackFit.expand,
          children: <Widget>[
            Transform.translate(
              offset: Offset(0, (1 - t) * 24 * scale),
              child: Opacity(opacity: t, child: inner),
            ),
            if (t < 1)
              IgnorePointer(
                child: ColoredBox(color: Colors.black.withValues(alpha: 1 - t)),
              ),
          ],
        );
      },
    );
  }

  /// 面板模型：每次按当前偏好快照重建（写进去 -> 立刻读回 -> 行显示新值的同一条链）。
  /// 原生渲染参数：唯一真值仍是 [_settings]，这里只是投影给 Qt 的那一份。
  BasicSceneSettings _sceneSettings() => BasicSceneSettings(
        discRotation: _settings.discRotation,
        archiveMaskStrength: _settings.archiveMaskStrength,
        // vsync/后端/分辨率/AA 下发的是**当前请求值**：Qt 侧把它写进 panel/*，
        // 下次启动由 main.cpp 读同一套偏好（所以"请求值 vs 生效值"仍然分得开）。
        vsync: _settings.requestedVsync,
        renderScale: _settings.renderScalePercent,
        graphicsBackend: _settings.requestedGraphicsBackend,
        aaMode: _settings.aaMode,
        aaScale: _settings.aaScalePercent,
        msaa: _settings.msaaSamples,
        supersample: _settings.supersampleFactor,
        // 封面查看器命令（不是偏好）：seq 单调，Qt 侧执行一次就记账，重复应用被丢掉。
        viewerSeq: _viewerCommandSeq,
        viewerAction: _viewerCommand,
        // 初始化页面在场 → 场景走 "boot"（Qt 同相位），否则回到 detail/archive。
        bootPhase: _startupPageOpen,
        // FSR（fsr-quality / fsr-sharpness）按用户 m03406 暂缓：持久化契约里仍有这两项
        // （basic_settings.dart 的 antiAliasing 细项），但本阶段既不出档位 UI，也不把
        // 它们塞进场景快照/不 qputenv，渲染器继续按自己的缺省（native / 50）走。
      );

  /// 设置面板滚动偏移（跨越开关面板保持；由 BasicSettingsWindow 写回）。
  final ValueNotifier<double> _settingsScroll = ValueNotifier<double>(0);

  BasicSettingsPanelModel _settingsPanelModel() {
    return basicSettingsPanelModel(
      context: _settingsContext(),
      snapshot: _settings.snapshot,
      // 版本必须是真值：读到的包信息优先；平台没给（例如纯 Dart 预览）时
      // 如实显示“未知版本”，绝不编一个像版本号的串。
      version: _settings.version ??
          BasicSettingsVersion(
            version: basicSettingsUnknownVersion,
            releaseBuild: false,
          ),
      expandedId: _settings.expandedId,
    );
  }

  /// 面板上下文：Android 基本版的真实平台能力（没有桌面歌词 / 官方音源 / 应用音量）。
  SettingsPreferenceContext _settingsContext() {
    return SettingsPreferenceContext(
      capabilities: const PlatformCapabilities.android(),
      operatingSystem: SettingsOperatingSystem.android,
      providerId: sirenProvider,
      musicEnabled: true,
      providerIsLocal: false,
      gpuDeviceCount: 1,
      direct3d12Available: false,
      temporalAntialiasingAvailable: false,
      frameGenerationClickable: false,
      aaMode: _settings.aaMode,
      appliedGraphicsBackend: _settings.effectiveGraphicsBackend,
      gpuAppliedIndex: -1,
    );
  }

  /// 设置浮层的唯一动作入口：命中串 -> typed 命令 -> 真实落盘 -> 真实效果。
  // 插件（Qt/src/Host.cpp 的插件子系统 + ResponsiveHudPages.cpp:683-852 的竖屏页）

  /// 管理器状态变化（安装进度、市场载入、启停）只推一帧重建。
  void _onPluginsChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  /// 详情页要显示的 manifest：已装插件用磁盘上的那份；市场里未安装的用条目临时拼，
  /// 这样「点市场行的详情」也能看到发布者/许可证等字段（Qt 同）。
  PluginManifest? _pluginDetailManifest() {
    if (_pluginDetailId.isEmpty) {
      return null;
    }
    final PluginSnapshot snapshot = _plugins.snapshot();
    final InstalledPlugin? installed = snapshot.installedById(_pluginDetailId);
    if (installed != null) {
      return installed.manifest;
    }
    final MarketPluginEntry? entry = snapshot.marketById(_pluginDetailId);
    return entry == null ? null : BasicPortraitPluginDetailPage.fromMarket(entry);
  }

  bool get _pluginDetailEnabled {
    final InstalledPlugin? installed =
        _plugins.snapshot().installedById(_pluginDetailId);
    return installed?.enabled ?? false;
  }

  bool get _pluginDetailUserInstalled {
    final InstalledPlugin? installed =
        _plugins.snapshot().installedById(_pluginDetailId);
    return installed?.userInstalled ?? false;
  }

  /// 详情页「回滚上一版本」是否可点：安装成功后 `.backup-<id>` 会保留（与 Qt 同）。
  /// 待确认卸载的插件 id（空 = 无确认框）。
  String _pendingPluginUninstall = '';

  bool get _pluginDetailCanRollback =>
      _pluginDetailId.isNotEmpty && _plugins.hasRollback(_pluginDetailId);

  /// 插件页动作（Qt `NativeHudController.cpp:748-826` 的 `plugin:*` 分支）。
  ///
  /// 拒绝文案沿用 Host 原文（「正在安装插件，请稍候」「插件市场中没有该插件」…），
  /// 不自己造一套：同一件事在两个前端说法必须一致。
  Future<void> _onPluginAction(String action) async {
    if (action == 'plugins') {
      // 入口：开弹层 + 读市场（Qt openModal 之后立刻 refreshPluginMarketplace）。
      _setModal('plugins');
      setState(() => _pluginDetailId = '');
      unawaited(_plugins.refreshMarket());
      return;
    }
    if (action == 'plugin:close-detail') {
      if (mounted) {
        setState(() {
          _pluginDetailId = '';
          _modal = 'plugins';
        });
      }
      return;
    }
    if (action == 'plugin:refresh') {
      await _plugins.refreshMarket();
      return;
    }
    if (action.startsWith('plugin:market:')) {
      final String id = action.substring('plugin:market:'.length);
      final String refusal = await _plugins.install(id);
      if (!mounted) {
        return;
      }
      if (refusal.isNotEmpty) {
        setState(() => _actionNotice = refusal);
      }
      return;
    }
    if (action.startsWith('plugin:detail:')) {
      if (!mounted) {
        return;
      }
      setState(() {
        _pluginDetailId = action.substring('plugin:detail:'.length);
        _modal = 'plugin-detail';
      });
      return;
    }
    if (action.startsWith('plugin:toggle:')) {
      final String id = action.substring('plugin:toggle:'.length);
      final InstalledPlugin? plugin = _plugins.snapshot().installedById(id);
      if (plugin == null) {
        return;
      }
      await _plugins.setEnabled(id, !plugin.enabled);
      return;
    }
    if (action.startsWith('plugin:uninstall:')) {
      // 先弹二次确认（Qt `Host.cpp:797-826`），确认后才真删。
      if (!mounted) {
        return;
      }
      setState(() => _pendingPluginUninstall =
          action.substring('plugin:uninstall:'.length));
      return;
    }
    if (action == 'plugin:uninstall-cancel') {
      if (!mounted) {
        return;
      }
      setState(() => _pendingPluginUninstall = '');
      return;
    }
    if (action.startsWith('plugin:uninstall-confirm:')) {
      final String id = action.substring('plugin:uninstall-confirm:'.length);
      if (mounted) {
        setState(() => _pendingPluginUninstall = '');
      }
      final String refusal = await _plugins.uninstall(id);
      if (!mounted) {
        return;
      }
      if (refusal.isNotEmpty) {
        setState(() => _actionNotice = refusal);
        return;
      }
      // 卸载后详情页没有对象可看，退回列表（Qt 删完 reloadPlugins 后仍停在列表）。
      setState(() {
        _pluginDetailId = '';
        _modal = 'plugins';
      });
      return;
    }
    if (action.startsWith('plugin:rollback:')) {
      // Qt `rollbackPlugin`：备份目录提为当前版本，失败换回，文案「插件已回滚」。
      final String id = action.substring('plugin:rollback:'.length);
      final String refusal = await _plugins.rollback(id);
      if (!mounted || refusal.isEmpty) {
        return;
      }
      setState(() => _actionNotice = refusal);
      return;
    }
    if (action == 'plugin:import') {
      setState(() => _actionNotice = '从文件导入插件尚未接入：本版只从市场安装');
    }
  }

  Future<void> _onSettingsAction(String action) async {
    if (action == 'plugins') {
      // 设置整页底部的「插件管理」卡：设置不是唯一真值来源，插件页自己读管理器。
      await _onPluginAction('plugins');
      return;
    }
    if (action == HudAction.closeModal) {
      // 设置窗自带的返回按钮回的就是 closeModal（SettingsModalFrame.backAction）。
      // 这里以前写 _setModal('settings')——面板已经开着时那是恒等操作，返回键点
      // 了没反应；按 Qt closeModal 语义应该是关掉当前弹层，并把焦点还给 HUD
      // （与 PopScope 的同一条路径一致）。
      _setModal('');
      _hudFocusNode.requestFocus();
      return;
    }
    if (action == 'disc-rotation:cancel') {
      // 风险弹层的“保持关闭”：不写任何值，退回设置面板。
      _setModal('settings');
      return;
    }
    final BasicSettingsApplyResult result =
        await _settings.apply(action, context: _settingsContext());
    if (!mounted) {
      return;
    }
    if (result.requiresWarning) {
      _setModal(DiscWarningModal.kind);
      return;
    }
    // 风险确认的**成功**分支：退回打开它的设置面板（关闭风险窗），让用户立刻看到
    // 开关已经是"开"、并且这一条真的落盘了。旧实现只处理了 'disc-rotation:cancel'，
    // 成功路径既没关窗也没退回——用户必须手动按返回，也就是"确认后窗口没有消失"。
    // 风险页在 Qt 侧就是设置面板上的一层弹层（NativeHudController 的 modal 栈），
    // 收掉它不等于关掉设置，所以这里回到 'settings' 而不是 ''。
    if (_modal == DiscWarningModal.kind) {
      _setModal('settings');
    }
    if (result.command is BasicSettingsActionRowCommand &&
        (result.command as BasicSettingsActionRowCommand).dispatchAction == 'replay') {
      // “手动显示初始化动画”：真的重放那一段动效，不弹 toast 了事。
      // 先收掉设置面板：Qt 侧 replay 就是场景相位切换（NativeHudController.cpp:698
      // → `m_scene.mode("boot")`），面板留在最上层会把整页初始化盖住——用户看不到
      // "重新显示"发生，就会以为这一项还是没反应。
      _setModal('');
      _hudFocusNode.requestFocus();
      _replayStartup();
      return;
    }
    _applySettingsEffects();
    setState(() {});
    if (result.notice.isNotEmpty) {
      _notice(result.notice);
    } else if (result.restartPending) {
      _notice('已保存：${_settings.pendingRestart.join('、')} 下次启动生效');
    }
  }

  void _onAction(String action) {
    // 详情页的「查看封面 ↗」（lib/hud/pages/song_detail.dart:710 的 'viewer' 命中）。
    // Qt 侧同一条：NativeHudController.cpp:688 value=="viewer" → scene.openViewer()。
    if (action == 'viewer') {
      _openCoverViewer();
      return;
    }
    // 3D 归档里点到某一格：Qt 只回传**几何格**（lane+物理行），条目身份仍由这里的
    // 唯一列表真值折出来。折不出来（不是当前列/空列）就不动，不猜下标。
    // 详情页唱片转到底：原生只报手势方向，切哪一张由这里的列表真值决定。
    final int? step = qtSceneStepOf(action);
    if (step != null) {
      unawaited(controller.stepDetailFromScene(step));
      return;
    }
    final QtSceneCellRef? cell = QtSceneCellRef.parse(action);
    if (cell != null) {
      final int? row = qtSceneRowOfCell(controller.state, cell);
      if (row != null) {
        // 手势进行中的身份回执一律丢掉：拖动松手 ≠ 选曲（见 selectCellFromScene）。
        unawaited(controller.selectCellFromScene(row));
      }
      return;
    }
    // Qt/src/NativeHudController.cpp:684：'search' 走 openModal("search")；
    // :686 'close-modal' 走 closeModal()。两者是弹层开关，不是“尚未接入”的动作。
    if (action == HudAction.search) {
      _setModal('search');
      return;
    }
    if (action == HudAction.closeModal) {
      if (_modal == DiscWarningModal.kind) {
        _setModal('settings');
        return;
      }
      _setModal('');
      return;
    }
    // 竖屏（compact）顶部来源 tab：直接换列（只选中不播放，见 selectLane）。
    if (action.startsWith(basicPortraitLaneActionPrefix)) {
      final int? lane = int.tryParse(action.substring(basicPortraitLaneActionPrefix.length));
      if (lane == null) {
        return;
      }
      unawaited(controller.selectLane(lane));
      return;
    }
    // 竖屏底栏：资料库 = 关掉弹层回主页；发现页本版没有内容，诚实提示不装作有。
    if (action == 'mobile:nav:archive') {
      _setModal('');
      return;
    }
    if (action == 'mobile:nav:discover') {
      setState(() => _actionNotice = '发现页尚未接入');
      return;
    }
    // 竖屏检索页的四列 tab = Qt 的四种检索分类（`music:kind:<i>`，i 是
    // [portraitSearchKindActionOrder] 的下标：0=歌曲、1=歌手、2=专辑、3=歌单）。
    // Qt `NativeHudMusic.cpp:218-236`：有词立即重搜、空词只换分类（见
    // BasicController.setSearchKind）。
    if (action.startsWith(basicPortraitSearchTabActionPrefix)) {
      final int? tab = int.tryParse(action.substring(basicPortraitSearchTabActionPrefix.length));
      if (tab == null || tab < 0 || tab >= portraitSearchKindActionOrder.length) {
        return;
      }
      final String kind = portraitSearchKindKeys[portraitSearchKindActionOrder[tab]];
      if (!controller.setSearchKind(kind)) {
        return;
      }
      return;
    }
    // 分组条（Qt `music:group:<i>` = none/artist/album，只对曲目分类生效）。
    if (action.startsWith(portraitSearchGroupActionPrefix)) {
      final int? group = int.tryParse(action.substring(portraitSearchGroupActionPrefix.length));
      if (group == null || group < 0 || group >= portraitSearchGroupKeys.length) {
        return;
      }
      controller.setSearchGroup(portraitSearchGroupKeys[group]);
      return;
    }
    // 展开某个分组（Qt `music:expand:<percentEncoded 标题>`）。
    if (action.startsWith(portraitSearchExpandActionPrefix)) {
      final String title = Uri.decodeComponent(
        action.substring(portraitSearchExpandActionPrefix.length),
      );
      controller.expandSearchGroup(title);
      return;
    }
    // 退出分组视图（Qt `music:group-back`）。
    if (action == portraitSearchGroupBackAction) {
      controller.clearSearchGroup();
      return;
    }
    // 竖屏详情页的「随机播放 / 更多」：模式本身已在下方按词表接入
    // （player:mode:<x>），这枚旧的无载荷 'player:mode' 命中按 Qt 的
    // `NativeHudController.cpp` "mode" 分支循环切到下一个模式。
    if (action == 'player:mode') {
      final int next = (portraitQueueModes.indexOf(controller.queueMode) + 1) %
          portraitQueueModes.length;
      controller.setQueueMode(portraitQueueModes[next]);
      setState(() => _queueModesExpanded = false);
      return;
    }
    // 播放队列（Qt ResponsiveHudLayout::handleAction :430-490 与
    // NativeHudController.cpp 的 player 动作分派）：模式区展开/收起、四模式切换。
    if (action == basicQueueModesAction) {
      setState(() => _queueModesExpanded = !_queueModesExpanded);
      return;
    }
    if (action.startsWith(basicQueueModeActionPrefix)) {
      final String mode = action.substring(basicQueueModeActionPrefix.length);
      if (controller.setQueueMode(mode)) {
        // Qt handleAction：点模式 chip 后收起展开区（:486-489）。
        setState(() => _queueModesExpanded = false);
      }
      return;
    }
    // 队列行：选中并播放该行（Qt "queue" → player.play(queue.at(index), index=i)）。
    if (action.startsWith(basicQueueRowActionPrefix)) {
      final int? index = int.tryParse(action.substring(basicQueueRowActionPrefix.length));
      if (index == null) {
        return;
      }
      unawaited(controller.playQueueIndex(index));
      return;
    }
    // 移除待播行（Qt "remove" → player.remove(index)；当前曲目由播放器拒绝）。
    if (action.startsWith(basicQueueRemoveActionPrefix)) {
      final int? index = int.tryParse(action.substring(basicQueueRemoveActionPrefix.length));
      if (index == null) {
        return;
      }
      controller.removeFromQueue(index);
      return;
    }
    // 清空待播（Qt "clear" → player.clearUpcoming()；当前曲目继续播放）。
    if (action == basicQueueClearAction) {
      controller.clearUpcoming();
      return;
    }
    // 分类检索的结果行（见 basic_hud.dart 的 _portraitSearchRows）：
    // 专辑行打开该专辑列（Qt selectResult(open=true) 对非 song 走 enterDirectory），
    // 歌手/歌单行本仓库没有详情页，给可见反馈。
    if (action.startsWith(basicSearchAlbumActionPrefix)) {
      final String name = Uri.decodeComponent(
        action.substring(basicSearchAlbumActionPrefix.length),
      );
      // 专辑行的数据源就是当前状态里的专辑列表（专辑分类的命中项），按标题取回。
      SirenAlbum? album;
      for (final SirenAlbum candidate in controller.state.albums) {
        if (candidate.name == name) {
          album = candidate;
          break;
        }
      }
      if (album == null) {
        setState(() => _actionNotice = '专辑已不在当前列表里');
        return;
      }
      unawaited(controller.enterAlbumColumn(album));
      _setModal('');
      return;
    }
    if (action.startsWith(basicSearchPlaylistActionPrefix)) {
      setState(() => _actionNotice = '歌单详情尚未接入');
      return;
    }
    if (action.startsWith(basicSearchArtistActionPrefix)) {
      setState(() => _actionNotice = '歌手页尚未接入');
      return;
    }
    // 音乐平台页（Qt `providerPage`）的入口与平台切换：`provider` 打开弹层，
    // `provider:<id>` 切到该平台。找不到就留可见反馈，不猜、不静默。
    if (action == 'provider') {
      _setModal('provider');
      return;
    }
    if (action.startsWith(basicProviderSwitchPrefix)) {
      final String id = action.substring(basicProviderSwitchPrefix.length);
      ProviderDescriptor? target;
      for (final ProviderDescriptor descriptor in _providers) {
        if (descriptor.id == id) {
          target = descriptor;
          break;
        }
      }
      final ProviderDescriptor? found = target;
      if (found == null) {
        setState(() => _actionNotice = '未知平台：$id');
        return;
      }
      setState(() => _actionNotice = '已切换至 ${found.name}');
      _setModal('');
      return;
    }
    // Qt `ResponsiveHudLayout::handle`（ResponsiveHudLayout.cpp:457-462）：
    // `mobile:song-options` 只翻转面板，任何 `music:`/`tab:` 动作都会把它收起。
    if (action == 'mobile:song-options') {
      setState(() => _songOptionsExpanded = !_songOptionsExpanded);
      return;
    }
    if (_songOptionsExpanded &&
        (action.startsWith('music:') || action.startsWith('tab:'))) {
      setState(() => _songOptionsExpanded = false);
    }
    if (action == 'music:enqueue' || action == 'music:play-next') {
      final bool next = action == 'music:play-next';
      unawaited(controller.enqueueCurrent(next: next).then((String notice) {
        if (!mounted) {
          return;
        }
        setState(() => _actionNotice = notice);
      }));
      return;
    }
    if (action == 'settings') {
      _setModal('settings');
      return;
    }
    // 插件：入口 'plugins'（设置页末尾的那张卡）+ 全部 'plugin:*' 动作。
    if (action == 'plugins' || action.startsWith('plugin:')) {
      unawaited(_onPluginAction(action));
      return;
    }
    final String? notice = _route(action);
    if (!mounted) {
      return;
    }
    // 只动动作槽：资源失败横幅不受点击影响（见 _resourceNotice 的注释）。
    setState(() => _actionNotice = notice);
  }

  /// 打开播放队列（Qt `openModal("player")`，NativeHudController.cpp）。
  ///
  /// 每次打开都把面板首行重置到当前曲目（Qt `queueOffset = max(0, queue.indexOf(current))`，
  /// 再 clamp 到 maximumOffset）；竖屏的滚动量交给页面按同一规则推算。
  void _openQueue() {
    if (!mounted) {
      return;
    }
    final int current = controller.state.queueIndex;
    final int count = controller.state.queue.length;
    setState(() {
      _queueOffset = current < 0 ? 0 : current;
      _queueOffset = _queueOffset.clamp(0, queueModalMaximumOffset(count));
      // Qt openModal("player") 不展开模式区（那是 `mobile:queue-modes` 的态）。
      _queueModesExpanded = false;
    });
    _setModal('queue');
  }

  /// 弹层开关。Qt 打开检索弹层时把 m_music->keyword 灌进输入框且【不】发检索
  /// （Qt/src/NativeHudController.cpp:117-119）；本外壳对应为 [_textInput] 把
  /// state.query 交给 Overlay，同样不调 setQuery。关闭也不清 controller 的 query
  /// （Qt closeModal 只清 editingSetting，NativeHudController.cpp:132-143，清理在
  /// :138-140；:145 起已是 setQuery）。
  /// 选项面板末尾的「专辑 / 时长」摘要（Qt `m_song->album + " / " + m_song->duration`）。
  String _songOptionsDetail(BasicViewState state) {
    final SirenSong? song = state.song;
    if (song == null) {
      return '';
    }
    final String album = song.album.isEmpty ? sirenUnknownTitle : song.album;
    final String duration = song.durationMs <= 0
        ? '--:--'
        : '${(song.durationMs ~/ 60000).toString().padLeft(2, '0')}:'
            '${((song.durationMs ~/ 1000) % 60).toString().padLeft(2, '0')}';
    return '$album / $duration';
  }

  /// 选项面板的详情正文（Qt `source["detailBody"]`）。本机没有独立的详情长文，
  /// 用曲目元信息组一条可读段落，不编造来源。
  String _songOptionsDetailBody(BasicViewState state) {
    final SirenSong? song = state.song;
    if (song == null) {
      return '';
    }
    final List<String> parts = <String>[
      if (song.artist.isNotEmpty) song.artist,
      if (song.album.isNotEmpty) song.album,
      '塞壬唱片',
    ];
    return parts.join(' · ');
  }

  void _setModal(String modal) {
    if (_modal == modal || !mounted) {
      return;
    }
    // Qt openModal 会 cacheMessage.clear()（Qt/src/NativeHudController.cpp:95）：
    // 开弹层时旧的动作反馈必须收起，否则「尚未接入」的提示会挂在搜索框上。
    // 资源失败横幅是另一槽（_resourceNotice），与弹层无关，不跟着清。
    setState(() {
      _modal = modal;
      if (modal.isNotEmpty) {
        _actionNotice = null;
      }
    });
  }

  /// 动作反馈单写口（见 [_actionNotice] 的两槽说明）。
  void _notice(String text) {
    if (!mounted) {
      return;
    }
    setState(() => _actionNotice = text);
  }

  // ── TextInputPorts（lib/hud/input/text_input_overlay.dart:361-391）────────────
  //
  // 输入层只在这里落地一次。composing / commit 的去重由 Overlay 自己的
  // TextCommitTracker 负责（text_input_overlay.dart:487-505：acceptText 与上一份
  // 已提交文本相同就返回 null、程序化回填后 resetTo），所以这里【不得】再加第二层
  // 去重——加了会把真实的组合态二次提交吞掉（中文输入法最典型）。

  /// Overlay.qml:549 → rhine.action("close-modal")：回到命中层。
  @override
  void action(String action) => _onAction(action);

  /// Overlay.qml:540（onTextEdited）→ Engine::query → NativeHud::setQuery
  /// （Qt/src/Engine.cpp:1022-1025、NativeHudController.cpp:145-163）。
  /// 真实检索入口只有 [BasicController.setQuery]，这里不做节流、不去重：
  /// Qt 的 setQuery 也不因取词相同而跳过（重新计时 700ms 再搜一次）。
  @override
  void query(String text) {
    // 不在外壳再加 700ms 计时器：Qt 把整次 m_music->search 推迟 700ms ——
    // schedule(700) 的 lambda 里才调 search（NativeHudController.cpp:145-163，:153
    // 起），在 lambda 真正执行前不发起任何检索，且没有 provider 条件；本版
    // BasicController.setQuery 的本地过滤与 publish 立即生效
    // （lib/basic/siren_controller.dart:183-205）。
    //
    // 这是【已知的可见时序差异】：Qt 的结果列表在最后一次击键后约 700ms 才更新，
    // 本版立即更新。外壳再加计时器会变成第二份时间源，并与 700ms 后的真实检索
    // 双触发，故不加，只记录差异。
    unawaited(controller.setQuery(text));
  }

  /// Overlay.qml:550-552 → Engine::searchAccepted（Qt/src/Engine.cpp:1006-1012）。
  @override
  void searchAccepted(String text, {required bool control}) {
    if (control) {
      // Qt 带 Control 时把回车交给键盘通路（NativeHudController.cpp:905-907 →
      // m_music->play()，播放当前队列项）。BasicController 有真实 play()
      // （lib/basic/siren_controller.dart:965），不再用 toggle 顶替、也不再只弹提示。
      unawaited(controller.play());
      return;
    }
    unawaited(controller.setQuery(text));
  }

  /// 账号表单（发送验证码 / 提交）在本外壳不可达：formVisible 只在
  /// modal ∈ {login, playlist-form} 时为真（text_input_overlay.dart 的
  /// TextInputStageState.formVisible），而本预览只有 '' 与 'search' 两个 modal，
  /// 账号三平台保持暂停。空实现是“不可达”，不是伪造动作；将来接登录必须换真实调用。
  @override
  void submitForm(String account, String captcha) {}

  @override
  void sendLoginCode(String phone) {}

  /// 设置编辑框同理不可达（editingSetting 恒为 false，设置页未接入）。
  @override
  void settingEditText(String text) {}

  @override
  void settingEditAccepted() {}

  @override
  void settingEditCancel() {}

  /// Overlay.qml:541-548（隐藏分支 :546）：输入框隐藏时 inputLayer.forceActiveFocus()，
  /// 把焦点交回 HUD 输入层（Qt 侧由 QML 焦点作用域实现）。
  ///
  /// 这里不能只 unmount 焦点：Qt 是「交还」，不是「丢掉」——直接 unfocus 会让
  /// 关框后没有任何节点持焦点，硬件键盘/遥控器导航断掉。
  @override
  void focusInputLayer() {
    if (!_hudFocusNode.hasFocus) {
      _hudFocusNode.requestFocus();
    }
  }

  /// 把输入层铺到窗口级。
  ///
  /// Overlay.qml:528-531 的 x / y / width 是「舞台值 × stageScale」的**逻辑像素**，
  /// 和 HUD 面板同处一个窗口坐标系。PortraitStage 的子树活在舞台单位里（外面套了
  /// Transform.scale，lib/ui/layout/portrait_stage.dart:34-150），把 Overlay 挂进去
  /// 会再乘一次 stageScale（竖屏 s≈0.38 时框只剩 1/2.6），所以挂在 Scaffold body 的
  /// Stack 上，用 [TextInputStageState.fromGeometry] 拿同一份 scale。
  ///
  /// [geometry] 为 null 表示竖屏首帧还没接管到作用域里的实例：这一帧不铺，第二帧再来。
  Widget? _textInput(
    BasicViewState state, {
    required StageGeometry? geometry,
    bool portrait = false,
  }) {
    if (geometry == null) {
      return null;
    }
    final Rect rect = _searchInputStageRect(geometry, portrait: portrait);
    // 竖屏的舞台原点被 PortraitStage 下移了 originY 个舞台单位（状态栏带，
    // lib/ui/layout/portrait_stage.dart:34-150 的 Padding(top: containerTop*stageScale)），
    // 而 Overlay 的 y 是「舞台值 × stageScale」、不带原点（Overlay.qml:529）。
    // 把 originY 折进舞台 y 才是 Qt 那个「y 从 HUD 原点量起」的坐标；横屏 originY
    // 恒为 0（StageGeometry 默认值），数字与 Qt 逐字相同。
    final double stageY = rect.top + geometry.originY;
    // 竖屏检索框的框高与字号都按 393 网格量（lib/hud/portrait/portrait_pages_library.dart
    // 的 `field('search', {58, y, 313, 44})`；字号取 Qt compact 的 14 网格，
    // Qt/src/ResponsiveHudPages.cpp:330 与 Qt/qml/Overlay.qml:542-543）。不传的话输入层
    // 会用 QML 的缺省 54 / 22，字小且贴在框上沿——用户 2026-11-19 报的「字小的小标题」。
    final double compactUnit =
        HudScale.portraitUnit(geometry.stageWidth, geometry.stageScale);
    return TextInputOverlay(
      state: TextInputStageState.fromGeometry(
        geometry,
        modal: _modal,
        // Qt/src/NativeHud.cpp:184-186 的 inputX / inputY / inputWidth（舞台单位），
        // 检索分支见 :154-157（:158 是 bounds 返回）。
        inputX: rect.left,
        inputY: stageY,
        inputWidth: rect.width,
        inputHeight: portrait ? 44.0 * compactUnit : null,
        inputFontSize: portrait ? 14.0 * compactUnit : null,
        // 本预览不播 Qt 的 0.3s 淡入 / 0.2s 淡出（Qt/src/UiMotion.cpp:101-120，
        // SurfaceMotion::set：shown duration 0.3 :112、hidden 0.2 :114，reduced 时
        // duration 0 瞬变）：打开即全不透明，关闭即不可见，属明示的未实现动画。
        // modalOpacity 同时是 QML 里输入框自身的 opacity（Overlay.qml:535），
        // 给 0 会让已经 visible 的框彻底透明——所以按弹层状态二值化。
        modalOpacity: _modal.isEmpty ? 0.0 : 1.0,
        // Qt NativeHudController.cpp:117-119：检索弹层打开时输入框取 m_music->keyword。
        query: state.query,
        dark: state.dark,
        // BasicGlyphPorts 没有 fontFamily getter（basic_hud_resources.dart:133-140 只暴露
        // glyphs/text 与各端口方法），字体族直接用常量（basic_hud_resources.dart:32）。
        rhineFontFamily: basicRhineMiSansFamily,
      ),
      ports: this,
    );
  }

  /// Qt/src/NativeHud.cpp:140-158（modalBounds，检索分支 :154-157）+ :184-186
  /// （input 矩形），逐项照抄；[stageWidth] 是舞台宽（= StageGeometry.stageWidth
  /// = HudStage.width）。
  ///
  /// libraryToolbarActionWidth() 只在 modal == 'saved' 时非 0
  /// （Qt/src/NativeHudLibrary.cpp:60-72），检索弹层恒为 0，所以 inputWidth 就是
  /// modalWidth - 106。height 54 是 QML 常量（Overlay.qml:531），由 Overlay 自己固定，
  /// 这里只填以保持矩形完整。
  static Rect _searchInputStageRect(StageGeometry geometry, {required bool portrait}) {
    final double stageWidth = geometry.stageWidth;
    if (portrait) {
      // 竖屏检索页（lib/hud/portrait/portrait_pages_library.dart 的
      // `field('search', Rect.fromLTWH(58, top, c.gridWidth - 78, 44))`）用的是网格坐标；
      // 这里把同一份网格矩形换回舞台单位，输入层就贴在画出来的框上。
      // 网格宽随 DPI 适配变化（比 393 宽），必须和绘制同源取 portraitGridWidth。
      final double unit = HudScale.portraitUnit(stageWidth, geometry.stageScale);
      final double gridWidth = HudScale.portraitGridWidth(stageWidth, geometry.stageScale);
      final double stageHeight =
          geometry.stageScale > 0 ? geometry.logicalHeight / geometry.stageScale : 852.0 * unit;
      final double gridHeight = unit > 0 ? stageHeight / unit : 852.0;
      final double top = math.min(126.0, gridHeight * .22);
      return Rect.fromLTWH(
        58.0 * unit,
        top * unit,
        (gridWidth - 78) * unit,
        44.0 * unit,
      );
    }
    final double modalWidth = math.min(
      stageWidth - 100.0,
      math.max(760.0, math.min(1000.0, stageWidth * 0.5 - 59.0)),
    );
    final double left = stageWidth - modalWidth - 59.0;
    return Rect.fromLTWH(
      left + 53.0,
      122.0 + 180.0,
      math.max(0.0, modalWidth - 106.0),
      54.0,
    );
  }

  /// 接管竖屏那份 [StageGeometry]（只存引用，不重算 scale）。
  ///
  /// [StageGeometry] 没有 operator==（lib/hud/input/hit_layer.dart:55-150），
  /// 所以按字段比较：值相同就不 setState，避免 PortraitStage 每帧新造实例
  /// 引起的无限重建。
  void _adoptPortraitGeometry(StageGeometry geometry) {
    final StageGeometry? current = _portraitGeometry;
    if (current != null &&
        current.stageScale == geometry.stageScale &&
        current.logicalWidth == geometry.logicalWidth &&
        current.logicalHeight == geometry.logicalHeight &&
        current.originY == geometry.originY) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((Duration _) {
      if (!mounted) {
        return;
      }
      setState(() => _portraitGeometry = geometry);
    });
  }

  /// 硬件键 → HUD 动作。Overlay.qml:118-120 / Engine.cpp:952-1012 /
  /// NativeHudController.cpp:887-943 的接线点。
  ///
  /// 只在这个焦点节点持焦时生效：检索框是**兄弟**节点（不是祖先链），输入法
  /// 持焦期间按键不会冒泡到这里，所以不抢输入框的 Return/Escape。
  KeyEventResult _onHudKeyEvent(FocusNode node, KeyEvent event) {
    // 查看器开着时 HUD 键路由整块让位：Esc 只关查看器（NativeViewer.cpp:132-134
    // "Escape 即使在网格没装载时也关"），不往下走 HUD/settings 的键。
    if (_coverViewer != null) {
      if (event is KeyDownEvent && event.logicalKey == LogicalKeyboardKey.escape) {
        _requestCloseCoverViewer();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }
    if (event is KeyUpEvent) {
      return KeyEventResult.ignored;
    }
    final HardwareKeyboard keyboard = HardwareKeyboard.instance;
    final EngineKeyOutcome outcome = _engineKeyRouter.keyEvent(
      basicHudKeyEvent(
        event,
        command: keyboard.isControlPressed || keyboard.isMetaPressed,
      ),
    );
    // Qt 把 Engine::keyEvent 的返回值直接赋给 event.accepted（Overlay.qml:118-120）；
    // 与 consumed 不是同一个东西：frameEmpty 时 HUD 不动作但 Engine 仍返回 true。
    return outcome.accepted ? KeyEventResult.handled : KeyEventResult.ignored;
  }

  /// NativeHud::key(...)：Qt 里 settingsScroll / desktopLyricsScroll 是 NativeHud
  /// 的成员变量，本外壳把 settingsScroll 换成真实滚动存储的读-改-写。
  HudKeyOutcome _dispatchHudKey(String value, bool command) {
    _keyScrollOffsets.settingsScroll = _settingsScroll.value;
    final HudKeyOutcome outcome = _keyRouter.key(
      _hudKeySnapshot(),
      _keyScrollOffsets,
      value: value,
      command: command,
    );
    if (outcome.region == 'settings') {
      // 步进被 clamp 在真实 maxScrollExtent 上，再写回面板的滚动存储（面板 jumpTo）。
      _settingsScroll.value = _keyScrollOffsets.settingsScroll;
    }
    if (outcome.region == 'settings' || outcome.region == 'desktop-lyrics') {
      setState(() {});
    }
    return outcome;
  }

  /// NativeHud 的状态投影。基础外壳没有 3D viewer 键域（viewer 键盘归 Qt 场景），
  /// 只有设置/桌面歌词两个弹层是滚动域；本外壳的 _modal 只有 ''/'search'/'settings'
  /// 与唱片确认弹层，故内容高度按 0 传（无弹层时用不到）。
  HudKeySnapshot _hudKeySnapshot() {
    final BasicViewState state = controller.state;
    return HudKeySnapshot(
      frameEmpty: state.phase == BasicPhase.boot,
      modal: _modal,
      closing: false,
      viewer: false,
      // NativeHudController.cpp:891-897 把 contentBottom - settingsViewportTop 当作
      // 「内容高度」再减视口高求上界，所以这里按同一算法反推：
      // contentBottom = viewportTop + 真实内容高（= maxScrollExtent + 视口高）。
      settingsContentBottom: _settingsScrollMaximum.value > 0
          ? HudWheelConstants.settingsViewportTop +
              _settingsScrollMaximum.value +
              (HudWheelConstants.settingsViewportBottom -
                  HudWheelConstants.settingsViewportTop)
          : 1600.0,
      desktopLyricsContentBottom: 0,
    );
  }

  /// 命中动作 → controller 调用；返回 null 表示已分派，返回文案表示这是
  /// 可见的“尚未接入”反馈（不静默 no-op、不伪造功能、不复制 controller）。
  String? _route(String action) {
    final BasicViewState state = controller.state;
    // 'player:lyrics-retry' 是歌词面板的重试热区（94 已上线），与 retry 同一条重读路径。
    if (action == 'retry' || action == 'player:lyrics-retry') {
      unawaited(controller.retry());
      return null;
    }
    // 'music:parent' 是 HUD 返回键（archive_page.dart 一级返回），与 back 同一条路径。
    if (action == 'back' || action == 'music:parent') {
      unawaited(controller.back());
      return null;
    }
    if (action == 'player:toggle') {
      unawaited(controller.togglePlay());
      return null;
    }
    // 播放器传输：只有 player:prev / player:next 才推播放队列
    // （Qt/src/NativeApplication.cpp:202-203 的 music.player.next）。
    if (action == 'player:prev') {
      unawaited(controller.previous());
      return null;
    }
    if (action == 'player:next') {
      unawaited(controller.next());
      return null;
    }
    // 竖屏详情页的传输键（详情曲目 ≠ 正在播放曲目时）：按**详情页所在列表**换曲，
    // 而不是推进播放队列。单曲详情页的控制带必须始终作用在页面上那首（用户
    // 2026-11-19：「详情页的控制始终是控制详情页对应曲目的」）。
    if (action == 'music:detail-prev') {
      unawaited(controller.playDetailSibling(-1));
      return null;
    }
    if (action == 'music:detail-next') {
      unawaited(controller.playDetailSibling(1));
      return null;
    }
    // HUD 的 ↑/↓ 是**逐项选曲**，不是播放器换曲（Qt/src/NativeHud.cpp:465/478 →
    // NativeHudController.cpp:655-660 → MusicLibrary::next(±1)，只动选中与滚动窗口）。
    if (action == 'prev' || action == 'next') {
      unawaited(controller.stepLibrarySelection(action == 'next' ? 1 : -1));
      return null;
    }
    // player:lyrics 仍是歌词面板；player:open 改开播放队列（Qt
    // NativeHudController.cpp 的 "open"：已经在队列页就关闭，否则打开并把
    // 当前曲目置顶）。竖屏点播放条、横屏点播放条中部都命中这一枚。
    if (action == 'player:lyrics') {
      unawaited(controller.openLyrics());
      return null;
    }
    if (action == 'player:open') {
      if (_modal == 'queue') {
        _setModal('');
        return null;
      }
      _openQueue();
      return null;
    }
    if (action == 'player:lyrics-close') {
      unawaited(controller.closeLyrics());
      return null;
    }
    // 详情页主按钮 'music:play'（song_detail.dart:755 无条件产出）是"真实播放"的入口：
    // 当前曲目 → controller.openSong（详情播放）；没有当前曲目 → 播放条语义的 toggle。
    // 两者都只走唯一 controller（94 已上线的语义，合并保留）。
    if (action == 'music:play') {
      final SirenSong? detailSong = state.song;
      if (detailSong != null) {
        unawaited(controller.openSong(detailSong));
      } else {
        // Qt NativeHudController.cpp:905-907 的 m_music->play()：播放，不是暂停开关。
        unawaited(controller.play());
      }
      return null;
    }
    // 'music:play-loaded'：曲库装载完成后"播放全部"热区，落到第一条真实条目并**播放**
    // （Qt/src/MusicLibrary.cpp:943-957 只在用户按下播放时才 replaceQueue）。
    if (action == 'music:play-loaded') {
      if (basicLibraryItems(state).isEmpty) {
        return basicEmptyLibraryNotice;
      }
      return _openAt(state, 0, play: true);
    }
    if (action.startsWith(basicSeekFractionActionPrefix)) {
      final double? fraction =
          double.tryParse(action.substring(basicSeekFractionActionPrefix.length));
      // NaN/Infinity 也是 tryParse 的"成功"（如 'NaN'），落到 controller 会毁掉播放位置。
      if (fraction == null || !fraction.isFinite) {
        return basicUnimplementedPrefix + action;
      }
      unawaited(controller.seekToFraction(fraction));
      return null;
    }
    if (action == 'open') {
      return _openSelected(state);
    }
    // 行点击 = **纯选中**（Qt/src/NativeHudMusic.cpp:79-91 的 selectResult/selectDirectory
    // 都是 open=false：只写 current/index/highlight，不回放、不换队列、不进详情）。
    if (action.startsWith(basicMusicIndexActionPrefix)) {
      final int? index = int.tryParse(action.substring(basicMusicIndexActionPrefix.length));
      if (index == null) {
        return basicUnimplementedPrefix + action;
      }
      return _selectAt(state, index);
    }
    // 'music:slot:<i>' 与 music:index:<i> 指向同一份列表下标（archive_page.dart:311）。
    if (action.startsWith(basicMusicSlotActionPrefix)) {
      final int? index = int.tryParse(action.substring(action.lastIndexOf(':') + 1));
      if (index == null) {
        return basicUnimplementedPrefix + action;
      }
      return _selectAt(state, index);
    }
    // 歌词行点击：按歌词时间轴换算进度（94 已上线的真实跳转，player 面板热区）。
    if (action.startsWith(basicLyricLineActionPrefix)) {
      final int? line = int.tryParse(action.substring(basicLyricLineActionPrefix.length));
      if (line == null ||
          line < 0 ||
          line >= state.lyrics.length ||
          !(state.durationMs > 0)) {
        return basicUnimplementedPrefix + action;
      }
      unawaited(controller.seekToFraction(state.lyrics[line].startMs / state.durationMs));
      return null;
    }
    // ←/→：目录内 ±8 换页（始终取模）、目录外按 sourceOrder() 换资料库列，
    // 两条分支都只选中/换列，不播放、不建队列（Qt/src/NativeHudController.cpp:650-662）。
    if (action == 'column-prev' || action == 'column-next') {
      unawaited(controller.navigateColumn(action == 'column-next' ? 1 : -1));
      return null;
    }
    // 检索：controller.setQuery 是真实过滤（Qt/src/MusicSiren.cpp:91-124）。
    // 载荷沿用本契约既有的 `动作:参数` 形状（music:index:<i>、player:seek-fraction:<f>）。
    // 裸 'search' 不在这里：它在 [_onAction] 里已被拦成 openModal("search")
    // （Qt/src/NativeHudController.cpp:684），承载文本走 TextInputOverlay 的
    // TextInputPorts.query，不再是“尚未接入”。
    if (action.startsWith(basicSearchActionPrefix)) {
      unawaited(controller.setQuery(action.substring(basicSearchActionPrefix.length)));
      return null;
    }
    // 'music:open-all-siren' 是 archive 页的「在资料库中打开 →」（archive_page.dart:255），
    // 对应 Qt QML 的同一个动作名（Qt/src/NativeHud.cpp:426）→ NativeHudMusic.cpp:365-369 →
    // MusicLibrary::openSirenAllSongs()（Qt/src/MusicSiren.cpp:193-246）：把**全部已加载曲目**
    // 当成虚拟歌单 'siren-all'/'siren:playlist:all'（title「全部歌曲」）打开，仅选中第一首，
    // 不替换播放队列、不开始播放。
    // 早期实现没有目录 API，用 openSirenLibrary 做近似（只回完整曲库、不开目录）；
    // 后来交付了逐字照抄 Qt 的 openAllSirenSongs（siren_controller.dart:360），二者在
    // 「回曲库 + 不动播放队列」上一致，但只有后者真的开出目录，所以这里按 Qt 指向后者，
    // 旧近似不再被调用（openSirenLibrary 仍留在 controller 里，由调用方处置，本次不改写）。
    if (action == 'music:open-all-siren') {
      unawaited(controller.openAllSirenSongs());
      return null;
    }
    if (action.startsWith(basicVolumeFractionActionPrefix)) {
      return '音量调节尚未接入：BasicController 还缺 setVolumeFraction（预览不伪造音量）';
    }
    if (action == 'music:login' || action == 'music:qr' || action == 'music:logout') {
      return '账号功能尚未接入：预览不伪造登录态';
    }
    return basicUnimplementedPrefix + action;
  }

  String? _openSelected(BasicViewState state) {
    final List<BasicListItem> items = basicLibraryItems(state);
    if (items.isEmpty) {
      return basicEmptyLibraryNotice;
    }
    return _openAt(state, basicSelectedItemIndex(state, items));
  }

  /// 索引全部越界就原地给可见反馈：不打开错的行，也不假装打开成功。
  ///
  /// 曲目行的 `item.index` 是 [basicLibraryItems] 的**列表内**下标，它指回哪份
  /// 列表随相位不同（真值只有一处：basic_models.dart 的 [basicLibraryItems]，
  /// 由 basic_hud.dart:39-66 原样迁入，控制器与绘制/命中共用）：
  /// * 专辑详情（phase == detail 且 album != null）→ album.songs；
  /// * 资料库首屏 → state.songs（这里 state.album 恒为 null，早期版本只看 album，
  ///   导致首屏每一行单曲都变成“尚未实现”，正是用户报的“点击没反应”）。
  String? _openAt(BasicViewState state, int index, {bool play = false}) {
    final List<BasicListItem> items = basicLibraryItems(state);
    if (index < 0 || index >= items.length) {
      return '${basicUnimplementedPrefix}music:index:$index';
    }
    final BasicListItem item = items[index];
    final SirenAlbum? album = state.album;
    if (item.kind == 'song') {
      final List<SirenSong> tracks =
          (state.phase == BasicPhase.detail && album != null) ? album.songs : state.songs;
      if (item.index < 0 || item.index >= tracks.length) {
        return '${basicUnimplementedPrefix}music:index:$index';
      }
      unawaited(controller.openSong(tracks[item.index], play: play));
      if (!play) {
        // 「打开」进详情：只有 detail-autoplay 开着才自动出声
        // （Qt/src/NativeHudController.cpp:626-638 的 music.play(false)）。
        // 浏览路径（music:index:<i> / music:slot:<i> → [_selectAt]）不经过这里，
        // 所以关着时点行永远不播。
        unawaited(controller.autoplayDetailIfEnabled(tracks[item.index]));
      }
      return null;
    }
    if (item.kind == 'playlist') {
      // 歌单行是**目录**，不是专辑（Qt/src/MusicSiren.cpp:251-335 的 playlists 分支走
      // selectDirectory）。把歌单行当专辑打开会显示一张不相干的专辑——这正是 132R 的
      // D2 缺陷。基础版没有本机歌单端口时不编造目录内容，如实标记未接入。
      return '${basicUnimplementedPrefix}music:playlist:${item.id.isEmpty ? item.index : item.id}';
    }
    if (item.index < 0 || item.index >= state.albums.length) {
      return '${basicUnimplementedPrefix}music:index:$index';
    }
    // 点专辑行 = **换列**（进入该专辑目录），不是抽唱片。
    // Qt/src/MusicLibrary.cpp:863-869：`mode = open && kind == "song" ? "detail" : "archive"`
    // 且 `if (open && current.kind != "song") enterDirectory(current)`。旧实现在这里调
    // openAlbum → 相位跳到 detail、3D 抽唱片（用户 2026-11-19 第 1 条）；顺带让单曲
    // 专辑一进去就只有一个当前行、任何点击都命中 'open'（第 2 条「必然触发」）。
    unawaited(controller.enterAlbumColumn(state.albums[item.index], play: play));
    return null;
  }

  /// 列表行的**纯选中**（Qt/src/NativeHudMusic.cpp:79-91 的 selectResult/selectDirectory
  /// 都是 open=false）：只写 current/index/highlight 与滚动窗口，不回放、不换队列、
  /// 不进详情。下标越界给可见反馈，不选错行、不假装成功。
  ///
  /// 旧实现把 'music:index:<i>' 直接交给 [_openAt]，那会 `_player.play(...)`——
  /// 于是"点一行"= 开始播放，正是用户报的"浏览就自动播放"。
  String? _selectAt(BasicViewState state, int index) {
    final List<BasicListItem> items = basicLibraryItems(state);
    if (index < 0 || index >= items.length) {
      return '${basicUnimplementedPrefix}music:index:$index';
    }
    unawaited(controller.selectLibraryRow(index));
    return null;
  }

  /// 系统返回键：只有资料库根（未打开目录）可以退出 App，目录、详情、歌词都在
  /// App 内退回上一相位（94 已上线的行为）。
  ///
  /// 判据必须同时看 [BasicViewState.directory]：在资料库里打开目录后 controller 仍是
  /// [BasicPhase.library]（siren_controller.dart:532-560 的 _openAllSirenDirectory 只设置
  /// _directory），只看 phase 会让系统返回键在目录里直接退出 App。Qt 侧返回键由 HUD 自己
  /// 消费（Qt/src/NativeHudController.cpp:643-654：目录打开时走 returnToDirectory()/
  /// leaveDirectory()，只有资料库根才冒泡到宿主退出）。
  ///
  /// 只转成既有 controller 调用，不新造导航栈、不改 PopScope 之外的返回语义。
  Widget _popScope(BasicViewState state, Widget child) {
    final bool libraryRoot =
        state.phase == BasicPhase.library && state.directory == null;
    // 开着模态（设置/搜索/风险确认）时返回键先收模态：面板盖在资料库根上，
    // 若还让 canPop=true，一按返回就把整个 App 退了。
    final bool modalOpen = _modal.isNotEmpty;
    // 查看器也是一层"盖在相位上的界面"：返回键先关它，不能直接退出 App，
    // 也不该顺手把详情页退掉（关掉后回到打开前的详情/列表）。
    final bool viewerOpen = _coverViewer != null;
    return PopScope(
      canPop: libraryRoot && !modalOpen && !viewerOpen,
      onPopInvoked: (bool didPop) {
        if (didPop) {
          return;
        }
        if (viewerOpen) {
          _requestCloseCoverViewer();
          return;
        }
        if (_startupPageOpen) {
          // 初始化页在场上时返回键 = Qt 的 skip（NativeHudController.cpp:682-683
          // 'skip' → archive），看完就正常回到原本相位，不做别的。
          _finishStartupPage();
          return;
        }
        if (_modal == DiscWarningModal.kind) {
          // 风险确认收起来后回到设置面板，不是直接关掉整页。
          _setModal('settings');
          return;
        }
        if (modalOpen) {
          // 关闭模态同时撤掉输入层 -> 焦点回到 HUD，输入法随之收起。
          _setModal('');
          _hudFocusNode.requestFocus();
          return;
        }
        if (state.phase == BasicPhase.lyrics) {
          unawaited(controller.closeLyrics());
          return;
        }
        // 详情（含目录内详情）与已打开目录都交给 controller.back()：它自己按
        // phase/directory 分派到 closeLyrics / 离开详情 / 返回上一级目录
        // （siren_controller.dart:294-324）。
        if (state.phase == BasicPhase.detail || state.directory != null) {
          unawaited(controller.back());
        }
      },
      child: child,
    );
  }
}

/// 启动阶段的可见状态页：装载中 / 失败 + 可选重试。
class _BasicMessage extends StatelessWidget {
  const _BasicMessage({
    required this.text,
    this.actionLabel,
    this.onAction,
  });

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
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text(
                text,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Color(0xFFE6E1DA), fontSize: 16),
              ),
              if (label != null && action != null) ...<Widget>[
                const SizedBox(height: 16),
                TextButton(
                  onPressed: action,
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

/// 未接入动作的可见反馈条：只显示文案，不吃命中、不伪装成设置/账号界面。
class _BasicNotice extends StatelessWidget {
  const _BasicNotice({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0xE6000000),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: const TextStyle(color: Color(0xFFE6E1DA), fontSize: 14),
      ),
    );
  }
}

/// [HudKeyPorts] 的本外壳实现：四个端口全部落到**产品里已有的**那条动作链，
/// 不新增第二条播放/导航路径。
class _BasicHudKeyPorts implements HudKeyPorts {
  _BasicHudKeyPorts(this._app);

  final _BasicShellState _app;

  /// Qt 的两条 Ctrl+Enter 入口完全同路（NativeHudController.cpp:905-907 与
  /// Overlay 键盘都是 key("Enter", true) → m_music->play()），所以这里也不绕
  /// _route('music:play')：那条详情按钮语义会 openSong(选中曲)，键盘不该借它。
  @override
  void play() => unawaited(_app.controller.play());

  @override
  void viewerKey(String value) => _app._onAction('viewer:$value');

  @override
  void action(String action) => _app._onAction(action);

  @override
  void togglePlayer() => unawaited(_app.controller.togglePlay());
}

/// 桥接层：Flutter 的 KeyEvent → Qt 的 (key, modifiers, text) 三元组。
///
/// Engine.cpp:952-1012 的判定顺序（媒体键 → 7 个翻译键 → event.text → 空则不接受）
/// 全部在 [EngineKeyRouter] 里，这里只负责把 Flutter 的键码翻成 [KeySymbol]，
/// 并把 `event.character` 当作 QKeyEvent::text()——翻译表因此只有一份真值。
HudKeyEvent basicHudKeyEvent(KeyEvent event, {bool command = false}) {
  final String? symbol = basicHudKeySymbol(event.logicalKey);
  String text = '';
  if (event is KeyDownEvent || event is KeyRepeatEvent) {
    text = event.character ?? '';
  }
  if (text.isEmpty && symbol == KeySymbol.space) {
    // Qt 里空格 key 与 text 都是 " "；某些平台键事件不带 character。
    text = KeySymbol.space;
  }
  return HudKeyEvent(
    symbol: symbol ?? '',
    key: event.logicalKey.keyId,
    text: text,
    command: command,
  );
}

/// Flutter 平台键 → Qt::Key 语义名（Engine.cpp:963-995 的翻译输入）。
///
/// 媒体键五枚（Engine.cpp:963-973）与七个被翻译的键（:974-995）；其余返回 null，
/// 由 `event.text` 决定（空格与 "/" 就属于这一类）。
String? basicHudKeySymbol(LogicalKeyboardKey key) {
  if (key == LogicalKeyboardKey.arrowLeft) {
    return KeySymbol.arrowLeft;
  }
  if (key == LogicalKeyboardKey.arrowRight) {
    return KeySymbol.arrowRight;
  }
  if (key == LogicalKeyboardKey.arrowUp) {
    return KeySymbol.arrowUp;
  }
  if (key == LogicalKeyboardKey.arrowDown) {
    return KeySymbol.arrowDown;
  }
  if (key == LogicalKeyboardKey.enter || key == LogicalKeyboardKey.numpadEnter) {
    return KeySymbol.enter;
  }
  if (key == LogicalKeyboardKey.escape) {
    return KeySymbol.escape;
  }
  if (key == LogicalKeyboardKey.tab) {
    return KeySymbol.tab;
  }
  if (key == LogicalKeyboardKey.space) {
    return KeySymbol.space;
  }
  if (key == LogicalKeyboardKey.mediaPlayPause) {
    return KeySymbol.mediaTogglePlayPause;
  }
  if (key == LogicalKeyboardKey.mediaPlay) {
    return KeySymbol.mediaPlay;
  }
  if (key == LogicalKeyboardKey.mediaPause) {
    return KeySymbol.mediaPause;
  }
  if (key == LogicalKeyboardKey.mediaTrackNext) {
    return KeySymbol.mediaNext;
  }
  if (key == LogicalKeyboardKey.mediaTrackPrevious) {
    return KeySymbol.mediaPrevious;
  }
  return null;
}

/// [EngineKeyPorts] 的本外壳实现：三处端口都落到唯一的产品动作链
/// （_onAction / _dispatchHudKey / controller.setQuery），不新增第二条路径。
class _BasicEngineKeyPorts implements EngineKeyPorts {
  _BasicEngineKeyPorts(this._app);

  final _BasicShellState _app;

  @override
  void action(String action) => _app._onAction(action);

  @override
  void key(String value, bool command) =>
      _app._dispatchHudKey(value, command);

  @override
  void query(String text) => unawaited(_app.controller.setQuery(text));
}

/// `BasicSettingsPort` → 异步 `PreferencePort` 的适配（键拼成 `panel/<key>`）。
///
/// 为什么不复用 `basic_settings_store.dart` 里那个私有的 `_PortAdapter`：
/// 它把键原样交给 `BasicSettingsStore` 的 port（后者只认已存在的 `panel/` 前缀
/// 键），而收藏的键是 `collections/<provider>.json`，必须在写之前自己加前缀。
/// 前缀与 `SharedPreferencesBasicSettingsPort.write` 的前缀校验一致，所以能真正
/// 落到 SharedPreferences，绕开的只是 `PreferenceStore.panelKeys` 白名单
/// （那张表逐项被设置页测试锁死，不能为了收藏往里加键）。
class _BasicSettingsPreferencePort implements PreferencePort {
  _BasicSettingsPreferencePort(this._store);

  final BasicSettingsStore _store;

  static const String _prefix = 'panel/';

  @override
  Future<String?> read(String key) async {
    final String value = await _store.read(key);
    return value.isEmpty ? null : value;
  }

  @override
  Future<void> write(String key, String value) async {
    final bool written = await _store.write(key, value);
    if (!written) {
      throw StateError('settings write rejected: $_prefix$key');
    }
  }

  @override
  Future<void> remove(String key) async {
    await _store.remove(key);
  }
}
