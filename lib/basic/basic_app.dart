import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app/consent_gate.dart';
import '../app/orientation_state.dart';
import '../hud/input/hit_layer.dart';
import '../hud/input/key_router.dart' show HudAction;
import '../hud/input/text_input_overlay.dart';
import '../hud/modals/disc_warning_modal.dart';
import '../hud/modals/settings_modal.dart'
    show
        PlatformCapabilities,
        SettingsOperatingSystem,
        SettingsPreferenceContext,
        SettingsPreferenceSnapshot;
import '../hud/player/player_bar.dart' show playerBarHeaderHeight, playerBarRowHeight;
import '../hud/protocol/hud_frame.dart';
import '../ui/layout/portrait_stage.dart';
import '../platform/media_session.dart';
import 'basic_hud.dart';
import 'basic_hud_resources.dart';
import 'basic_models.dart';
import 'basic_settings.dart';
import 'basic_settings_runtime.dart';
import 'basic_settings_store.dart';
import 'basic_settings_view.dart';
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

/// 音量载荷前缀：`player:volume-fraction:<0..1>`（player_bar.dart:529）。
/// 本版没有音量 API，命中必须给可见反馈，不能静默吃掉。
const String basicVolumeFractionActionPrefix = 'player:volume-fraction:';

/// 歌词行载荷前缀：`player:lyric-line:<i>`（94 已上线的歌词跳转热区）。
const String basicLyricLineActionPrefix = 'player:lyric-line:';

/// 选曲槽载荷前缀：`music:slot:<i>`（archive_page.dart:311，与 music:index: 同一份下标）。
const String basicMusicSlotActionPrefix = 'music:slot:';

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
  /// [MethodChannelBasicSettingsPort]；widget 测试注入 [MemoryBasicSettingsPort]。
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
        BasicSettingsStore(port: widget.settingsPort ?? MethodChannelBasicSettingsPort());
    _ownsAudio = widget.audio == null;
    _ownsController = widget.controller == null;
    _audio = widget.audio ?? MethodChannelBasicAudio();
    // 系统媒体控件端口：显式注入优先；否则只在"自己造 controller + 自己造 audio"
    // 的生产装配里接平台通道（widget 测试一律注入依赖，因此不会碰通道）。
    final MediaSessionPort? mediaPort = widget.mediaSessionPort ??
        (widget.controller == null && widget.audio == null
            ? (kIsWeb ? null : MethodChannelMediaSession())
            : null);
    _controller =
        widget.controller ?? BasicController(audio: _audio, mediaSessionPort: mediaPort);
    // 3D 场景的连续滚动回执（拖动/惯性/滚轮）落到同一个 controller 窗口真值上：
    // 方向 B（3D → 列表/ruler）因此不依赖 HUD 是否接了 onScroll 参数。
    QtSceneScrollRouter.instance.handler = _sceneScrollHandler;
    // 两路互不依赖：曲库走网络，字形走 asset。并行启动，任一失败都不会互相取消。
    unawaited(_boot());
    unawaited(_loadResources());
  }

  /// Qt 把连续条目增量报回来：拖动/惯性中途只滚窗口，松手才 commit 落行。
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
      final BasicHudResources resources = await BasicHudResources.load(bundle: widget.bundle);
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
    // 挂载是入口 lane（父/94 集成）的一件事，本原子只交付这个组合根；
    // MaterialApp 由本 widget 提供，所以挂上去即可直接 runApp(const BasicApp())。
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(brightness: Brightness.dark, scaffoldBackgroundColor: Colors.black),
      home: _home(),
    );
  }

  Widget _home() {
    final Object? bootError = _bootError;
    if (bootError != null) {
      return _BasicMessage(
        text: basicBootFailurePrefix + '$bootError',
        actionLabel: '重试',
        onAction: () => unawaited(_retryBoot()),
      );
    }
    final Object? resourceError = _resourceError;
    if (resourceError != null) {
      return _BasicMessage(
        text: basicResourceFailurePrefix + '$resourceError',
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
    super.key,
    required this.controller,
    required this.resources,
    required this.settingsStore,
  });

  final BasicController controller;
  final BasicHudResources resources;

  /// 面板偏好的唯一存储（`panel/<key>`）。设置页写、启动读、效果读的都是它。
  final BasicSettingsStore settingsStore;

  @override
  State<_BasicShell> createState() => _BasicShellState();
}

class _BasicShellState extends State<_BasicShell>
    with SingleTickerProviderStateMixin
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

  /// 当前弹层（'' = 无，'search' = 检索）。Qt 的 modal 由 NativeHud 自己持有
  /// （Qt/src/NativeHudController.cpp:64-130 openModal / :132-143 closeModal /
  /// :145-163 setQuery），BasicViewState 没有这个字段，也不在本原子写域
  /// （basic_models.dart 不可改），所以它落在外壳里。
  ///
  /// 只有 '' 与 'search'：登录表单 / 歌单表单 / 设置编辑在本预览里没有入口
  /// （账号三平台暂停、设置页未接入），不伪造第三态。
  String _modal = '';

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
  bool _startupEnabled = false;

  /// 设置项“右侧画面遮罩”的强度真值（0..100）。默认即 Qt 常量，装载后取偏好值。
  double _archiveMaskStrength = 55;

  /// 竖屏唯一 [StageGeometry] 的引用（横屏不用）。
  ///
  /// 实例由 PortraitStage 在 Transform.scale 内部造（lib/ui/layout/portrait_stage.dart:34-150），
  /// 这里只【接管】同一实例，绝不自己调 computePortraitBands / withScale 再推一份
  /// （DEDUP-13：scale 只允许一个来源）。接管发生在首帧后，所以竖屏首帧不铺输入层。
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

  BasicController get controller => widget.controller;

  @override
  void initState() {
    super.initState();
    _resourceNotice = _resourceFailuresNotice(widget.resources);
    _settings = BasicSettingsRuntime(store: widget.settingsStore);
    _startup.addStatusListener(_onStartupStatus);
    unawaited(_loadSettings());
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
    if (!mounted) {
      return;
    }
    _applySettingsEffects(replayStartup: true);
    setState(() {});
  }

  void _applySettingsEffects({bool replayStartup = false}) {
    controller.setDark(_settings.dark);
    controller.setDetailAutoplay(_settings.detailAutoplay);
    controller.setSinglePlayAppend(_settings.singlePlayAppend);
    _archiveMaskStrength = _settings.archiveMaskStrength.toDouble();
    _startupEnabled = _settings.startupAnimation;
    if (replayStartup && _startupEnabled) {
      _replayStartup();
    }
  }

  void _replayStartup() {
    if (!mounted) {
      return;
    }
    _startup.forward(from: 0);
    setState(() {});
  }

  @override
  void dispose() {
    _startup.dispose();
    _hudFocusNode.dispose();
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
                  // 横屏：几何体每帧现造一份，绘制 / 命中 / 输入层共用这一个实例（DEDUP-13）。
                  final StageGeometry? landscape = portrait
                      ? null
                      : StageGeometry(logicalWidth: width, logicalHeight: height);
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
    final Widget hud = BasicHudSurface(
      state: state,
      ports: widget.resources.ports,
      onAction: _onAction,
      // 场景层的身份键在 App 状态里（不在 surface 里）：横竖屏会换掉 surface 的
      // 父链（PortraitStage ↔ 直挂 Stack），只有把 key 抬到上层，PlatformView 的
      // element 才能被移动而非重建。
      sceneKey: _sceneKey,
      // 渲染参数投影：disc/mask 逐帧生效，其余四项（后端/vsync/渲染分辨率/AA）
      // 在 Android 上是"写进 Qt 的 panel/* 偏好、下次启动生效"（main.cpp 启动读）。
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
    );
    final bool settingsOpen =
        _modal == 'settings' || _modal == DiscWarningModal.kind;
    final bool animating = _startup.isAnimating;
    if (!settingsOpen && !animating) {
      return hud;
    }
    final double scale = stage?.scale ?? 1.0;
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        _startupCurtain(hud, scale: scale),
        if (settingsOpen)
          Builder(
            builder: (BuildContext inner) {
              final HudStage resolved = stage ?? HudStageScope.of(inner);
              return Stack(
                fit: StackFit.expand,
                children: <Widget>[
                  BasicSettingsOverlay(
                    stage: resolved,
                    ports: widget.resources.ports,
                    model: _settingsPanelModel(),
                    dark: state.dark,
                    onAction: (String action) => unawaited(_onSettingsAction(action)),
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
      ],
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
      );

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
  Future<void> _onSettingsAction(String action) async {
    if (action == HudAction.closeModal) {
      _setModal('settings');
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
    if (result.command is BasicSettingsActionRowCommand &&
        (result.command as BasicSettingsActionRowCommand).dispatchAction == 'replay') {
      // “手动显示初始化动画”：真的重放那一段动效，不弹 toast 了事。
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
    if (action == 'settings') {
      _setModal('settings');
      return;
    }
    final String? notice = _route(action);
    if (!mounted) {
      return;
    }
    // 只动动作槽：资源失败横幅不受点击影响（见 _resourceNotice 的注释）。
    setState(() => _actionNotice = notice);
  }

  /// 弹层开关。Qt 打开检索弹层时把 m_music->keyword 灌进输入框且【不】发检索
  /// （Qt/src/NativeHudController.cpp:117-119）；本外壳对应为 [_textInput] 把
  /// state.query 交给 Overlay，同样不调 setQuery。关闭也不清 controller 的 query
  /// （Qt closeModal 只清 editingSetting，NativeHudController.cpp:132-143，清理在
  /// :138-140；:145 起已是 setQuery）。
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
      // m_music->play()，播放当前队列项）。BasicController 没有 play()，只有
      // togglePlay()（lib/basic/siren_controller.dart:331）：拿 toggle 顶替会把
      // “播放”变成“暂停”，所以不伪造，只留可见反馈。
      _notice('控制键回车尚未接入：Qt 走 m_music->play()，BasicController 只有 togglePlay()');
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
  Widget? _textInput(BasicViewState state, {required StageGeometry? geometry}) {
    if (geometry == null) {
      return null;
    }
    final Rect rect = _searchInputStageRect(geometry.stageWidth);
    // 竖屏的舞台原点被 PortraitStage 下移了 originY 个舞台单位（状态栏带，
    // lib/ui/layout/portrait_stage.dart:34-150 的 Padding(top: containerTop*stageScale)），
    // 而 Overlay 的 y 是「舞台值 × stageScale」、不带原点（Overlay.qml:529）。
    // 把 originY 折进舞台 y 才是 Qt 那个「y 从 HUD 原点量起」的坐标；横屏 originY
    // 恒为 0（StageGeometry 默认值），数字与 Qt 逐字相同。
    final double stageY = rect.top + geometry.originY;
    return TextInputOverlay(
      state: TextInputStageState.fromGeometry(
        geometry,
        modal: _modal,
        // Qt/src/NativeHud.cpp:184-186 的 inputX / inputY / inputWidth（舞台单位），
        // 检索分支见 :154-157（:158 是 bounds 返回）。
        inputX: rect.left,
        inputY: stageY,
        inputWidth: rect.width,
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
  static Rect _searchInputStageRect(double stageWidth) {
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
    // HUD 的 ↑/↓ 是**逐项选曲**，不是播放器换曲（Qt/src/NativeHud.cpp:465/478 →
    // NativeHudController.cpp:655-660 → MusicLibrary::next(±1)，只动选中与滚动窗口）。
    if (action == 'prev' || action == 'next') {
      unawaited(controller.stepLibrarySelection(action == 'next' ? 1 : -1));
      return null;
    }
    // 本版没有独立的“正在播放”浮层：player:open / player:lyrics 都落到歌词面板。
    if (action == 'player:open' || action == 'player:lyrics') {
      unawaited(controller.openLyrics());
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
        unawaited(controller.togglePlay());
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
    // 94 当年没有目录 API，用 openSirenLibrary() 做近似（只回完整曲库、不开目录）；98 交付了
    // 逐字照抄 Qt 的 openAllSirenSongs()（siren_controller.dart:360），二者在「回曲库 + 不动
    // 播放队列」上一致，但只有后者真的开出目录，所以这里按 Qt 指向后者，94 的近似不再被调用
    // （openSirenLibrary 仍留在 98 的 controller 里，由它的 owner 处置，不在本整合改写）。
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
      return basicUnimplementedPrefix + 'music:index:$index';
    }
    final BasicListItem item = items[index];
    final SirenAlbum? album = state.album;
    if (item.kind == 'song') {
      final List<SirenSong> tracks =
          (state.phase == BasicPhase.detail && album != null) ? album.songs : state.songs;
      if (item.index < 0 || item.index >= tracks.length) {
        return basicUnimplementedPrefix + 'music:index:$index';
      }
      unawaited(controller.openSong(tracks[item.index], play: play));
      return null;
    }
    if (item.kind == 'playlist') {
      // 歌单行是**目录**，不是专辑（Qt/src/MusicSiren.cpp:251-335 的 playlists 分支走
      // selectDirectory）。把歌单行当专辑打开会显示一张不相干的专辑——这正是 132R 的
      // D2 缺陷。基础版没有本机歌单端口时不编造目录内容，如实标记未接入。
      return basicUnimplementedPrefix + 'music:playlist:${item.id.isEmpty ? item.index : item.id}';
    }
    if (item.index < 0 || item.index >= state.albums.length) {
      return basicUnimplementedPrefix + 'music:index:$index';
    }
    unawaited(controller.openAlbum(state.albums[item.index]));
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
      return basicUnimplementedPrefix + 'music:index:$index';
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
    return PopScope(
      canPop: libraryRoot && !modalOpen,
      onPopInvoked: (bool didPop) {
        if (didPop) {
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
    super.key,
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
  const _BasicNotice({super.key, required this.text});

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
