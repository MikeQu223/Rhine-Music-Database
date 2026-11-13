import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app/consent_gate.dart';
import '../app/orientation_state.dart';
import '../hud/input/hit_layer.dart';
import '../hud/player/player_bar.dart' show playerBarHeaderHeight, playerBarRowHeight;
import '../hud/protocol/hud_frame.dart';
import '../ui/layout/portrait_stage.dart';
import 'basic_hud.dart';
import 'basic_hud_resources.dart';
import 'basic_models.dart';
import 'platform_playback.dart';
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
/// 真实文本输入控件已经存在：lib/hud/input/text_input_overlay.dart:994 的
/// `TextInputOverlay`（端口 :361 `TextInputPorts.query/searchAccepted`）。本原子只按既有
/// `动作:参数` 契约接住检索词；把 Overlay 铺进 BasicApp（含 composing/commit 去重与
/// 唯一 StageGeometry）是下一个原子，尚未接线，所以这里不伪造输入框。
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

  @override
  State<BasicApp> createState() => _BasicAppState();
}

class _BasicAppState extends State<BasicApp> {
  /// 唯一音频端口：initState 装配一次，跨旋转/重建不再新建。
  late final BasicAudioPort _audio;

  /// 唯一 controller：initState 装配一次，跨旋转/重建不再新建。
  late final BasicController _controller;

  BasicHudResources? _resources;
  Object? _resourceError;
  Object? _bootError;

  /// 所有权在 initState 一次定死：只有自己创建的依赖才由自己 dispose。
  /// 不读 widget.*（那是可变的）：否则父级把注入改成 null 时会把注入方的实例
  /// 一起 dispose（双重释放），或反过来漏掉自持实例（泄漏）。
  late final bool _ownsAudio;
  late final bool _ownsController;

  @override
  void initState() {
    super.initState();
    _ownsAudio = widget.audio == null;
    _ownsController = widget.controller == null;
    _audio = widget.audio ?? MethodChannelBasicAudio();
    _controller = widget.controller ?? BasicController(audio: _audio);
    // 两路互不依赖：曲库走网络，字形走 asset。并行启动，任一失败都不会互相取消。
    unawaited(_boot());
    unawaited(_loadResources());
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
    return _BasicShell(controller: _controller, resources: resources);
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
  });

  final BasicController controller;
  final BasicHudResources resources;

  @override
  State<_BasicShell> createState() => _BasicShellState();
}

class _BasicShellState extends State<_BasicShell> {
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

  BasicController get controller => widget.controller;

  @override
  void initState() {
    super.initState();
    _resourceNotice = _resourceFailuresNotice(widget.resources);
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
                  if (!portrait) {
                    // 横屏沿用 Qt 全窗口高（Main.qml:32），几何与命中读同一份。
                    return _popScope(
                      state,
                      _surface(
                        state,
                        geometry: StageGeometry(logicalWidth: width, logicalHeight: height),
                        stage: HudStage.fromLogicalSize(width: width, height: height),
                      ),
                    );
                  }
                  // 竖屏由 PortraitStage 注入唯一的 StageGeometry/HudStage 作用域。
                  return _popScope(state, PortraitStage(child: _surface(state)));
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
    return BasicHudSurface(
      state: state,
      ports: widget.resources.ports,
      onAction: _onAction,
      geometry: geometry,
      stage: stage,
    );
  }

  void _onAction(String action) {
    final String? notice = _route(action);
    if (!mounted) {
      return;
    }
    // 只动动作槽：资源失败横幅不受点击影响（见 _resourceNotice 的注释）。
    setState(() => _actionNotice = notice);
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
    if (action == 'player:prev' || action == 'prev') {
      unawaited(controller.previous());
      return null;
    }
    if (action == 'player:next' || action == 'next') {
      unawaited(controller.next());
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
    // 'music:play-loaded'：曲库装载完成后"播放全部"热区，落到第一条真实条目。
    if (action == 'music:play-loaded') {
      if (basicLibraryItems(state).isEmpty) {
        return basicEmptyLibraryNotice;
      }
      return _openAt(state, 0);
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
    if (action.startsWith(basicMusicIndexActionPrefix)) {
      final int? index = int.tryParse(action.substring(basicMusicIndexActionPrefix.length));
      if (index == null) {
        return basicUnimplementedPrefix + action;
      }
      return _openAt(state, index);
    }
    // 'music:slot:<i>' 与 music:index:<i> 指向同一份列表下标（archive_page.dart:311）。
    if (action.startsWith(basicMusicSlotActionPrefix)) {
      final int? index = int.tryParse(action.substring(action.lastIndexOf(':') + 1));
      if (index == null) {
        return basicUnimplementedPrefix + action;
      }
      return _openAt(state, index);
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
    // 专辑列左右翻页（archive_page.dart:318 的 '←'/'→' 与 key_router.dart:156 的箭头键）。
    if (action == 'column-prev' || action == 'column-next') {
      _cycleAlbum(state, action == 'column-next' ? 1 : -1);
      return null;
    }
    // 检索：controller.setQuery 是真实过滤（Qt/src/MusicSiren.cpp:100-124）。
    // 载荷沿用本契约既有的 `动作:参数` 形状（music:index:<i>、player:seek-fraction:<f>）。
    // 真实输入控件 TextInputOverlay（lib/hud/input/text_input_overlay.dart:994）已存在，
    // 但本原子还没把它铺进 BasicApp，所以承载文本只能从 action 来；裸 'search' 给可见反馈。
    if (action.startsWith(basicSearchActionPrefix)) {
      unawaited(controller.setQuery(action.substring(basicSearchActionPrefix.length)));
      return null;
    }
    if (action == 'search') {
      return '检索输入框尚未接线：TextInputOverlay 已存在但还没铺进预览（不伪造搜索框）';
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
    if (action == 'settings' || action.startsWith('settings:')) {
      return '设置页尚未接入：预览不提供设置项（不伪造已有设置）';
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
  /// 列表随相位不同（basic_hud.dart:39-66 同一份真值）：
  /// * 专辑详情（phase == detail 且 album != null）→ album.songs；
  /// * 资料库首屏 → state.songs（这里 state.album 恒为 null，早期版本只看 album，
  ///   导致首屏每一行单曲都变成“尚未实现”，正是用户报的“点击没反应”）。
  String? _openAt(BasicViewState state, int index) {
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
      unawaited(controller.openSong(tracks[item.index]));
      return null;
    }
    if (item.index < 0 || item.index >= state.albums.length) {
      return basicUnimplementedPrefix + 'music:index:$index';
    }
    unawaited(controller.openAlbum(state.albums[item.index]));
    return null;
  }

  /// 专辑列左右翻页（archive_page.dart:318 的 '←'/'→' 与 key_router.dart 的箭头键）：
  /// 只按当前专辑在真实 albums 列表里的位置换一首，空曲库不动作。
  void _cycleAlbum(BasicViewState state, int delta) {
    if (state.albums.isEmpty) {
      return;
    }
    final String currentId = state.album?.id ?? '';
    final int current = state.albums.indexWhere((SirenAlbum album) => album.id == currentId);
    final int next = current < 0 ? 0 : (current + delta) % state.albums.length;
    unawaited(controller.openAlbum(state.albums[next < 0 ? next + state.albums.length : next]));
  }

  /// 系统返回键：曲库根是唯一可退出相位，详情/歌词先退回上一相位（94 已上线的行为）。
  /// 只转成既有 controller 调用，不新造导航栈、不改 PopScope 之外的返回语义。
  Widget _popScope(BasicViewState state, Widget child) {
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
