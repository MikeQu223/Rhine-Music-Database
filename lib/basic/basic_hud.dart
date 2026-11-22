import 'dart:math' as math;

import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, visibleForTesting;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart' show Ticker;

import '../hud/input/hit_layer.dart';
import '../hud/modals/lyrics_panel.dart' as lyrics;
import '../hud/modals/modal_shell.dart';
import '../hud/modals/comments_modal.dart' as comments_modal;
import '../hud/modals/login_modal.dart' as login_modal;
import '../hud/modals/mv_modal.dart' as mv_modal;
import '../hud/modals/provider_modal.dart' as provider_modal;
import '../hud/modals/queue_modal.dart' as queue_modal;
import '../hud/modals/search_panel.dart' as search_panel;
import '../hud/pages/archive_page.dart';
import '../hud/pages/chrome.dart';
import '../hud/pages/song_detail.dart' as detail;
import '../hud/portrait/portrait_canvas.dart';
import '../hud/portrait/portrait_layout.dart';
import '../hud/portrait/portrait_pages_library.dart';
import '../hud/portrait/portrait_pages_provider.dart';
import '../hud/portrait/portrait_playlist_picker.dart';
import '../hud/portrait/portrait_saved_overview.dart';
import '../hud/portrait/portrait_discover_page.dart';
import '../hud/portrait/portrait_pages_queue.dart';
import '../hud/portrait/portrait_pages_search_kinds.dart';
import '../hud/portrait/portrait_pages_song.dart';
import '../hud/portrait/portrait_song_options.dart';
import '../hud/player/player_bar.dart' as player;
import '../plugin/plugin_models.dart';
import '../plugin/plugin_manager.dart';
import '../provider/provider_descriptor.dart';
import '../domain/account/login_controller.dart'
    show LoginState;
import '../hud/portrait/portrait_pages_collection_likes.dart';
import '../hud/portrait/portrait_pages_collection_playlists.dart';
import '../hud/portrait/portrait_pages_comments.dart';
import '../hud/portrait/portrait_pages_mv.dart';
import '../hud/portrait/portrait_pages_login.dart';
import '../provider/provider_gateway.dart' show ProviderAccount, ProviderLoginMethod;
import '../hud/protocol/hud_frame.dart';
import '../hud/protocol/hud_hit.dart';
import '../hud/render/hud_painter.dart';
import '../hud/widgets/track_ruler.dart' as ruler;
import '../ui/layout/portrait_stage.dart';
import 'basic_hud_resources.dart';
import 'basic_discover_mapper.dart';
import 'basic_models.dart';
import 'library_gesture_adapter.dart';
import 'qt_scene_view.dart';

// 列表真值（BasicListItem / basicLibraryItems / basicSelectedItemIndex）住在
// basic_models.dart：controller 选曲与 HUD 绘制/命中必须用同一份顺序，
// 所以这里只做再导出，保持既有 import 站点不变。
export 'basic_models.dart' show BasicListItem, basicLibraryItems, basicSelectedItemIndex;

/// 资料库名（Qt NativeHud.cpp:380 的 "MUSIC DATABASE / <libraryName>"）。
const String basicLibraryName = '塞壬唱片';

/// 竖屏重排时曲目列的旧固定带顶（stage unit）。
///
/// 现在竖屏 3D/列表按 1:1 分割（[portraitListTop] 与 [basicSceneStageRect] 都取
/// 舞台高的一半）；这个常量只留给拿不到可视高度时的旧调用点兜底。
const double basicPortraitListOffset = 1080.0;

/// 竖屏列表块的位移（stage unit）：让 ruler 裁剪窗口的上沿
/// （[ruler.trackRulerWindowTop] = 219）正好落在 [basicPortraitListOffset] 那条带顶线上，
/// 也就是「曲目列从 1080 开始」这句注释的字面含义。
///
/// 直接平移 [basicPortraitListOffset]（旧实现）会把整块 610 高的窗口从 219 挪到 1299：
/// 选中行 titleY 509→1589，正好压到播放条上沿（stageHeight-96），窗口只露出选区一行。
/// 真机 1800×2880 → 舞台 1080×1728：可见带只有 1080..1632，1299..1909 里有 4 行
/// 藏在播放条下面、带顶还空出 219 高的空档。
const double basicPortraitListShift =
    basicPortraitListOffset - ruler.trackRulerWindowTop;

/// 侧栏起点：Qt NativeHud.cpp:408 `navigationLeft(width) = width - 789`。
double basicNavigationLeft(double width) => width - 789;

/// 资料库标题（Qt MusicLibrary::libraryName()，Qt/src/MusicLibrary.cpp:188-193）：
/// 目录打开时是目录标题（'全部歌曲'），否则是**当前列名**（`columns.value(lane)`：
/// 搜索结果 / 喜欢的歌曲 / 我的歌单 / 全部歌曲 / 全部专辑）。
String basicLibraryTitle(BasicViewState state, {String providerName = basicLibraryName}) {
  final BasicDirectory? directory = state.directory;
  if (directory != null) {
    // Qt/src/MusicLibrary.cpp:189-193：目录内就是 directory->item["title"]。
    // 目录确实可能没标题（来源没给），那时回落到 provider 名——不编造标题，
    // 也不拿根列的列名冒充目录名（目录不是列）。
    return directory.title.isEmpty ? providerName : directory.title;
  }
  final String lane = state.laneName(state.selectedLane);
  return lane.isEmpty ? providerName : lane;
}

/// 一帧的扁平命令流 + 命中集合。绘制（HudStagePainter）与命中（HitLayer）
/// 消费同一份，禁止各自再推导坐标。
class BasicHudFrame {
  BasicHudFrame({
    required this.generation,
    required this.commands,
    required this.hits,
    this.fields = const <String, Rect>{},
    this.animating = false,
  });

  final int generation;
  final List<List<Object?>> commands;
  final List<HudHit> hits;

  /// 本帧的输入框矩形（舞台单位，键是 `field(name, rect)` 的 name）。
  ///
  /// 宿主在派发命中之前先查这张表：点中的若是输入框，就把焦点交给输入层，
  /// 不再依赖输入层自己的命中面与 HUD 画出来的框完全重合。
  final Map<String, Rect> fields;

  /// 本帧绘制结束后，共享滚动文字是否仍有字符槽在动。宿主
  /// （[BasicHudSurface]）据此续帧；静止帧为 false，不空转 ticker。
  final bool animating;

  static int _generation = 0;

  static BasicHudFrame build({
    required BasicViewState state,
    required BasicGlyphPorts ports,
    required double width,
    required double height,
    required bool portrait,
    /// 拖动中的临时滚动位置（条目单位）；null = 用 state.listPosition。
    double? listPosition,
    /// 本帧的共享滚动文字时钟（秒，与 kReelDuration 同单位）。宿主 ticker 推进；
    /// 缺省 0 时首帧仍会画静态文字（RollingLabel 首帧 alpha=1），不会空白。
    double animationTime = 0,
    /// 是否让值变化走卷动动画；false 时滚动标签退化为单条静态 text。
    ///
    /// 默认 **false**：没有帧时钟的调用点（离屏/测试逐帧构造）必须拿到与旧行为
    /// 同形的单条 text 命令（如整条歌名），不能因为它们不推进时间就把文字拆成
    /// 逐字槽或整段不画。宿主 [BasicHudSurface] 有 ticker，显式传 true。
    bool animateText = false,
    /// 当前弹层（'' = 无，'search' = 检索，'settings' = 设置，'queue' = 播放队列）。
    /// 竖屏用它决定画哪一页：设置窗是真实 Flutter widget 层（不走命令流），
    /// 检索页与播放队列页是命令流页面；横屏队列面板由本帧叠加（见下）。
    String modal = '',
    /// 横屏队列面板的滚动偏移（Qt `queueOffset`，行单位）。
    /// 调用方负责 clamp 到 [queue_modal.queueModalMaximumOffset]。
    int queueOffset = 0,
    /// 竖屏队列页的滚动量（Qt `m_scroll`，网格单位）。null = 按 Qt 的
    /// `newScope` 缺省规则「当前行置顶」（当前行 > 0 时 251 + index*68）。
    double? queueScroll,
    /// 竖屏队列页的播放模式 chip 是否展开（Qt `m_queueModesExpanded`，
    /// 由 `mobile:queue-modes` 翻转）。横屏面板不用它（四模式按钮常驻）。
    bool queueModesExpanded = false,
    /// 横屏检索面板的行级滚动偏移（舞台像素，0 = 首行贴表头）。宿主拖动列表时
    /// 只改这一个临时量，不碰库表的 `listPosition`（那是资料库列的真值）。
    double searchScroll = 0,
    /// 右栏遮罩强度（0..100，Qt `archive-mask-strength` / 设置页“右侧画面遮罩”）。
    /// 默认就是 Qt 常量 [HudChrome.defaultArchiveMaskStrength]；注入只来自设置页真值。
    double archiveMaskStrength = 0, // = HudChrome.defaultArchiveMaskStrength（int 常量转 double）
    /// 资料库列表页的「列表形式」真值（Qt `NativeHud::trackListMode`）：
    /// true = 右栏是曲目列表；false = 右栏是当前条目的单条面板（Tab Mode 切换）。
    /// 只影响资料库列表页的绘制分支，不参与选中/滚动真值。
    bool trackListMode = true,
    /// 舞台缩放（逻辑像素 / 舞台单位）。竖屏用它把「1 网格 = 1.3dp」的 DPI 策略
    /// 换算成网格宽度（见 [HudScale.portraitGridWidth]）；0 = 旧口径（1 网格 = 屏宽/393）。
    double stageScale = 0,
    /// 插件管理页的数据真值（modal == 'plugins' 时用）。页面内容本身是 widget 层
    /// （`basic_plugins_portrait.dart`），HUD 只画纸色 + 通用页头 + 播放条/底栏。
    PluginSnapshot? plugins,
    /// 插件详情（modal == 'plugin-detail'）；null 时详情页不画。
    PluginManifest? pluginDetail,
    bool pluginDetailEnabled = true,
    bool pluginDetailUserInstalled = true,
    bool pluginDetailCanRollback = false,
    String pluginMessage = '',
    /// 竖屏「歌曲操作」面板是否展开（Qt `m_songOptionsExpanded`，
    /// `mobile:song-options` 翻转；任何 `music:`/`tab:` 动作都会收起）。
    bool songOptionsExpanded = false,
    /// 「关联 MV」是否可用（当前平台 descriptor 声明 `capabilities.mv` 或
    /// `operations.mvVersions`；Qt 移动端该路径恒关，见 `PlatformFeatures.h:23-27`）。
    bool mvAvailable = false,
    /// 「查看评论」是否可用（Qt `commentsAvailable` = 非 local 且评论 provider 非空；
    /// siren 在 descriptor 里 `operations.comments` 为 false，因此这里是 false）。
    bool commentsAvailable = false,
    /// 当前详情曲目的「专辑 / 时长」摘要与详情正文（Qt `optionsSheet` 末尾两行）。
    String songOptionsDetail = '',
    String songOptionsDetailBody = '',
    /// 音乐平台页的数据真值（`modal == 'provider'` 时用）：平台表已按
    /// `display.order` 排好（见 `ProviderRegistry.ids`）。
    List<ProviderDescriptor> providers = const <ProviderDescriptor>[],
    /// 当前平台 id（`music.provider`，决定平台行高亮与 ACCOUNT 段分支）。
    String providerId = '',
    /// 当前平台显示名（Qt `providerName()`）。切到插件平台后横屏页头/页脚、
    /// 详情页的 provider 字段都必须跟着换，不能继续写死「塞壬唱片」。
    String providerName = basicLibraryName,
    /// 当前平台是否就是内置塞壬（Qt `isSiren()`）。false 时横屏页头的
    /// 「＋ 塞壬曲库」应变成「＋ 我的音乐」、页脚 session 不再是 SIREN RECORDS。
    bool isSirenProvider = true,
    /// 平台 id → 已恢复的账号；null / 未登录即「未登录」。
    Map<String, ProviderAccount?> providerAccounts = const <String, ProviderAccount?>{},
    /// `music.nickname`（仅登录态使用）。
    String providerUserName = '',
    /// `PlatformFeatures::LocalMusic`：关掉时 `local` 平台不进列表
    /// （Qt `providerCardsState()` 跳过 `id == "local"`；过滤是调用方的事，
    /// `paintPortraitProviderPage` 不重复判断）。
    /// 当前帧的评论页数据（`modal == 'comments'`）：由宿主把
    /// `CommentState` 经 `basic_comment_mapper` 映射成竖屏只读视图模型。
    PortraitCommentsModel? comments,
    /// 评论页滚动位置（Qt `NativeHudController.cpp:483` 打开时归零，拖动改它）。
    double commentsScroll = 0,
    /// 登录页状态（`modal == 'login'`，Qt `music:login` 打开的那一层）。
    LoginState? loginState,
    /// 当前平台的登录方式（Qt `loginMethods`，未 open 时为空表）。
    List<ProviderLoginMethod> loginMethods = const <ProviderLoginMethod>[],
    /// 登录页的平台名（Qt `providerName()`）。
    String loginProviderName = '',
    /// 平台 `strings.scanHint`（空则用 Qt 兜底串）。
    String loginScanHint = '',
    /// 平台 `strings.deviceNotice`（空则不画）。
    String loginDeviceNotice = '',
    /// 冷却文案（Qt `loginPanel` 现算：`请等待 N 秒后重新生成` / `正在处理扫码登录…`）。
    String loginCooldownLabel = '',
    /// 短信重发剩余秒数（Qt `smsRetrySeconds()`）。
    int loginSmsRetrySeconds = 0,
    /// 收藏列（`modal == 'saved'`）要画哪一列：1 = 喜欢的歌曲、2 = 我的歌单；
    /// 其它值（含 0）= 画「我的音乐」总览。Qt 的真值是两个布尔
    /// `m_savedOverview` / `musicCollection`（`ResponsiveHudLayout.cpp:455-464`）。
    int savedLane = 0,
    /// 收藏列是否停在「我的音乐」总览（Qt `m_savedOverview`）。
    bool savedOverview = true,
    /// 收藏列数据：喜欢曲目（`BasicViewState` 没有单独的 likes 列，由宿主从
    /// 控制器取；空表 = 还没读到）。
    List<PortraitLikesRow> likedRows = const <PortraitLikesRow>[],
    /// 收藏列数据：本机歌单。
    List<PortraitPlaylistRow> playlistRows = const <PortraitPlaylistRow>[],
    /// 收藏计数（`X 首` / `Y 个歌单` 的读数），空串 = 未知。
    String savedNotice = '',
    /// MV 面板数据（`modal == 'mv'`）：由宿主把 `MvState` 经 `basic_mv_mapper`
    /// 映射成面板视图模型；null = 没有可展示的 MV 态。
    MvPanelModel? mv,
    /// MV 面板播放位置（毫秒；面板只用来画 `静音跟随音乐 · Np` 那句附注）。
    double mvPositionMs = 0,
    /// 「加入歌单」选择器（Qt compact `playlist-picker`，`NativeHudMusic.cpp:483`）
    /// 的可选歌单与状态行；空表时页面画空态。
    List<(String, String, int)> pickerPlaylists =
        const <(String, String, int)>[],
    String pickerNotice = '',
    bool canCreatePlaylist = false,
    /// 「我的音乐」总览（Qt `m_savedOverview`）用的平台名/用户名与收藏列行。
    String savedProviderName = '',
    String savedUserName = '',
    List<PortraitSavedOverviewRow> savedOverviewRows = const <PortraitSavedOverviewRow>[],
    bool savedShowArtists = false,
    double savedScroll = 0,
    /// 发现页（`modal == 'discover'`）：tab chip、条目、状态行与「加载更多」。
    /// 发现页（`modal == 'discover'`）的一帧快照；null = 不进发现页。
    BasicDiscoverSnapshot? discover,
    bool localMusicEnabled = true,
  }) {
    final bool dark = state.dark;
    // 竖屏（compact）走独立排版：393 网格、归档主页 + 迷你播放条 + 底栏，
    // 与横屏的 1080 设计稿是两套几何，不能互相平移/缩放复用。
    if (portrait) {
      return _buildPortraitFrame(
        state: state,
        ports: ports,
        width: width,
        height: height,
        dark: dark,
        listPosition: listPosition,
        animationTime: animationTime,
        animateText: animateText,
        modal: modal,
        stageScale: stageScale,
        queueScroll: queueScroll,
        queueModesExpanded: queueModesExpanded,
        plugins: plugins,
        pluginDetail: pluginDetail,
        pluginDetailEnabled: pluginDetailEnabled,
        pluginDetailUserInstalled: pluginDetailUserInstalled,
        pluginDetailCanRollback: pluginDetailCanRollback,
        pluginMessage: pluginMessage,
        songOptionsExpanded: songOptionsExpanded,
        commentsAvailable: commentsAvailable,
        mvAvailable: mvAvailable,
        songOptionsDetail: songOptionsDetail,
        songOptionsDetailBody: songOptionsDetailBody,
        providers: providers,
        providerId: providerId,
        providerName: providerName,
        isSirenProvider: isSirenProvider,
        providerAccounts: providerAccounts,
        providerUserName: providerUserName,
        localMusicEnabled: localMusicEnabled,
        comments: comments,
        commentsScroll: commentsScroll,
        loginState: loginState,
        loginMethods: loginMethods,
        loginProviderName: loginProviderName,
        loginScanHint: loginScanHint,
        loginDeviceNotice: loginDeviceNotice,
        loginCooldownLabel: loginCooldownLabel,
        loginSmsRetrySeconds: loginSmsRetrySeconds,
        savedLane: savedLane,
        savedOverview: savedOverview,
        likedRows: likedRows,
        playlistRows: playlistRows,
        savedNotice: savedNotice,
        mv: mv,
        mvPositionMs: mvPositionMs,
        pickerPlaylists: pickerPlaylists,
        pickerNotice: pickerNotice,
        canCreatePlaylist: canCreatePlaylist,
        savedProviderName: savedProviderName,
        savedUserName: savedUserName,
        savedOverviewRows: savedOverviewRows,
        savedShowArtists: savedShowArtists,
        discover: discover,
        savedScroll: savedScroll,
      );
    }
    final _HudSink sink = _HudSink();
    // 本帧绑定：滚动标签与静态 hudText 走同一个 sink、同一发射顺序，
    // ink 取同一 hudInk(dark)，暗/亮主题不会画出两套颜色。
    ports.beginFrame(
      sink: sink,
      time: animationTime,
      ink: hudInk(dark),
      animate: animateText,
    );
    HudChrome(sink, ports, dark: dark).chromeView(
      width: width,
      archiveMode: state.phase == BasicPhase.library && !portrait,
      // 场景铺满整窗（见 basicSceneStageRect），3D 会画到右栏文字下面，所以归档态必须
      // 让 HudChrome 自己盖右栏遮罩（lib/hud/pages/chrome.dart:231 的 archiveMask，
      // fadeWidth 300 = 原 Qt 的 NativeHud.cpp:313-330 FadeWidth）。
      suppressMask: false,
      libraryName: basicLibraryTitle(state, providerName: providerName),
      isLocal: false,
      isSiren: isSirenProvider,
      uid: '',
      provider: providerId,
      archiveMaskStrength: archiveMaskStrength.round(),
      updaterAvailable: false,
    );

    final bool songPage = state.song != null &&
        (state.phase == BasicPhase.detail || state.phase == BasicPhase.lyrics);
    if (songPage) {
      final detail.SongDetailDrawing drawing = detail.renderSongDetail(
        _detailState(
          state,
          providerId: providerId,
          providerName: providerName,
          isSiren: isSirenProvider,
        ),
        width,
        glyphs: ports,
        images: const _NoImages(),
      );
      sink.addDrawing(_commandRows(drawing.commands), drawing.hits);
      if (drawing.delegatedTo == detail.songDetailDelegateLyricsPanel) {
        final double x = width * 0.56;
        final double usable = width - x - 59;
        final lyrics.LyricsPanelDrawing panel = lyrics.paintLyricsPanel(
          _lyricsModel(state, x, usable),
          ports,
        );
        sink.addDrawing(panel.commands, panel.hits);
      }
    } else {
      _paintLibrary(
        sink,
        ports,
        state,
        width,
        portrait: portrait,
        listPosition: listPosition,
        trackListMode: trackListMode,
        providerId: providerId,
        providerName: providerName,
        isSirenProvider: isSirenProvider,
      );
    }

    // 横屏播放队列面板（Qt `modal == "player"`）：宿主先画全舞台遮罩 + 836 面板底，
    // 面板内容由 queue_modal 产出（NativeHudModal.cpp:163-186 对 player 不走标题区）。
    if (modal == 'search') {
      // Qt `modal == "search"` 走通用弹层路径（`Qt/src/NativeHudModal.cpp:163-202`）：
      // 遮罩 + 贴右的面板 + 标题带，内容由 NativeHudSearch 在面板内画
      // （工具栏 / 分类 / 分组 / 表头 / 列表 / 页脚）。这里把同一套内容交给
      // search_panel，行数据复用竖屏检索页已移植的投影（见 _portraitSearchRows）。
      _paintSearchModal(
        sink,
        ports,
        state,
        width,
        dark,
        searchScroll,
        localMusicEnabled,
      );
    } else if (modal == 'queue') {
      _paintQueueModal(sink, ports, state, width, height, dark, queueOffset);
    } else if (modal == 'comments' && comments != null) {
      _paintCommentsPanel(sink, ports, comments, width, height, dark, commentsScroll);
    } else if (modal == 'mv' && mv != null) {
      _paintMvModal(sink, ports, mv, width, mvPositionMs, dark);
    } else if (modal == 'login' && loginState != null) {
      _paintLoginModal(sink, ports, loginState, loginMethods, loginProviderName, loginScanHint,
          loginDeviceNotice, loginCooldownLabel, width, dark);
    } else if (modal == 'provider') {
      _paintProviderModal(sink, ports, providers, providerId, providerAccounts, width, dark,
          localMusicEnabled);
    } else if (modal == 'discover' || modal == 'playlist-picker') {
      // 我的音乐 / 发现页 / 加入歌单只有 393 网格的竖屏排版（Qt 桌面端用 library
      // 模态承载，本仓库还没有横屏稿）。横屏下不能什么都不画：这里用同一套 painter
      // 按舞台高度重采样（unit = 高度 / 852），保证内容与动作都可达。
      _paintPortraitPageInLandscape(
        sink,
        ports: ports,
        state: state,
        width: width,
        height: height,
        dark: dark,
        modal: modal,
        savedLane: savedLane,
        savedOverview: savedOverview,
        likedRows: likedRows,
        playlistRows: playlistRows,
        savedNotice: savedNotice,
        savedProviderName: savedProviderName,
        savedUserName: savedUserName,
        savedOverviewRows: savedOverviewRows,
        savedShowArtists: savedShowArtists,
        savedScroll: savedScroll,
        discover: discover,
        pickerPlaylists: pickerPlaylists,
        pickerNotice: pickerNotice,
        canCreatePlaylist: canCreatePlaylist,
      );
    }

    final player.PlayerBarDrawing bar = player.renderPlayerBar(
      _playerState(state, musicVideo: mvAvailable),
      player.PlayerBarRect(0, height - player.playerBarRowHeight, width, player.playerBarRowHeight),
      dark,
      ports,
    );
    sink.addDrawing(bar.commands, bar.hits);

    final bool animating = ports.endFrame();
    _generation += 1;
    return BasicHudFrame(
      generation: _generation,
      commands: sink.commands,
      hits: sink.hits,
      animating: animating,
    );
  }

  /// 分类检索页的行：把 `BasicViewState.searchRows` 的 Map 投影成
  /// [PortraitSearchKindsRow]（标题 / 明细行 / 右锚戳 / 点击动作）。
  ///
  /// 动作串按分类分派（Qt `NativeHudMusic.cpp` 的 `result` 与 `index` 两个分支）：
  /// 曲目行用 `music:index:<i>`（只选中，进入详情由宿主再决定），专辑/歌单/歌手行
  /// 用 `music:expand:<percentEncoded 标题>`，与 Qt `music:expand:` 同一个词表。
  static List<PortraitSearchKindsRow> _portraitSearchRows(BasicViewState state) {
    final List<PortraitSearchKindsRow> rows = <PortraitSearchKindsRow>[];
    for (final Map<String, Object?> item in state.searchRows) {
      final String kind = (item['kind'] ?? '').toString();
      final String title = (item['title'] ?? '').toString();
      final String artist = (item['artist'] ?? '').toString();
      // Qt `searchRowDetail`：明细行优先艺人，否则专辑（本地歌单两者皆空）。
      final String detail = artist.isNotEmpty
          ? artist
          : (item['album'] ?? '').toString();
      // 曲目行右侧是时长（Qt `MusicData::time(value)`），专辑/歌手是曲目数，
      // 歌单没有右列（参考图 m13779 的 `03:21` 就是这一列）。
      final String stamp = switch (kind) {
        'album' => '${item['trackCount'] ?? 0} 首',
        'artist' => '${item['trackCount'] ?? 0} 首',
        'playlist' => '歌单',
        _ => _trackTime(item['durationMs']),
      };
      // 行点击按分类分派：曲目只选中（`music:index:<i>`，与 Qt 的行下标同义）；
      // 专辑进专辑列（Qt `selectResult(open=true)` 对非 song 走 enterDirectory）；
      // 歌手/歌单本仓库还没有详情页，给可见反馈而不是静默吞掉。
      final String action = switch (kind) {
        // 远端（插件平台）的行不在本地 lane 里：`music:index:<i>` 会指到塞壬曲库，
        // 所以换成专用动作，由宿主向插件要播放地址再打开。
        'song' => state.searchRemote
            ? 'music:search-open:${rows.length}'
            : 'music:index:${rows.length}',
        'album' => 'music:search-album:${Uri.encodeComponent(title)}',
        'playlist' => 'music:search-playlist:${Uri.encodeComponent(item['id']?.toString() ?? '')}',
        _ => 'music:search-artist:${Uri.encodeComponent(title)}',
      };
      rows.add((title: title, artist: detail, stamp: stamp, action: action));
    }
    return rows;
  }

  /// 毫秒 → `mm:ss`（Qt `MusicData::time`；未知时长回空串，行右列留白）。
  static String _trackTime(Object? durationMs) {
    final double ms = durationMs is num ? durationMs.toDouble() : 0;
    if (ms <= 0) {
      return '';
    }
    final int seconds = ms.round() ~/ 1000;
    final int minutes = seconds ~/ 60;
    final int rest = seconds % 60;
    return '${minutes.toString().padLeft(2, '0')}:${rest.toString().padLeft(2, '0')}';
  }

  /// 竖屏一帧：`Qt/src/ResponsiveHudPages.cpp` 的 archive 页。
  ///
  /// 页面集合当前只有归档主页这一屏；详情/歌词/检索/设置仍由既有 Flutter 层
  /// （弹层与 widget 窗口）负责，不在这一帧里画——竖屏移植只改「主页长什么样」。
  static BasicHudFrame _buildPortraitFrame({
    required BasicViewState state,
    required BasicGlyphPorts ports,
    required double width,
    required double height,
    required bool dark,
    double? listPosition,
    double animationTime = 0,
    bool animateText = false,
    String modal = '',
    double stageScale = 0,
    double? queueScroll,
    bool queueModesExpanded = false,
    PluginSnapshot? plugins,
    PluginManifest? pluginDetail,
    bool pluginDetailEnabled = true,
    bool pluginDetailUserInstalled = true,
    bool pluginDetailCanRollback = false,
    String pluginMessage = '',
    bool songOptionsExpanded = false,
    bool commentsAvailable = false,
    bool mvAvailable = false,
    String songOptionsDetail = '',
    String songOptionsDetailBody = '',
    List<ProviderDescriptor> providers = const <ProviderDescriptor>[],
    String providerId = '',
    String providerName = basicLibraryName,
    bool isSirenProvider = true,
    Map<String, ProviderAccount?> providerAccounts = const <String, ProviderAccount?>{},
    String providerUserName = '',
    bool localMusicEnabled = true,
    PortraitCommentsModel? comments,
    double commentsScroll = 0,
    LoginState? loginState,
    List<ProviderLoginMethod> loginMethods = const <ProviderLoginMethod>[],
    String loginProviderName = '',
    String loginScanHint = '',
    String loginDeviceNotice = '',
    String loginCooldownLabel = '',
    int loginSmsRetrySeconds = 0,
    int savedLane = 0,
    bool savedOverview = true,
    List<PortraitLikesRow> likedRows = const <PortraitLikesRow>[],
    List<PortraitPlaylistRow> playlistRows = const <PortraitPlaylistRow>[],
    String savedNotice = '',
    MvPanelModel? mv,
    double mvPositionMs = 0,
    List<(String, String, int)> pickerPlaylists =
        const <(String, String, int)>[],
    String pickerNotice = '',
    bool canCreatePlaylist = false,
    String savedProviderName = '',
    String savedUserName = '',
    List<PortraitSavedOverviewRow> savedOverviewRows = const <PortraitSavedOverviewRow>[],
    bool savedShowArtists = false,
    double savedScroll = 0,
    /// 发现页（`modal == 'discover'`）：tab chip、条目、状态行与「加载更多」。
    /// 发现页（`modal == 'discover'`）的一帧快照；null = 不进发现页。
    BasicDiscoverSnapshot? discover,
  }) {
    final _HudSink sink = _HudSink();
    ports.beginFrame(sink: sink, time: animationTime, ink: hudInk(dark), animate: animateText);
    final PortraitMetrics metrics = _portraitMetrics(ports);
    final double unit = portraitUnit(width, stageScale: stageScale);
    // 页面铺满舞台：网格宽度 = 舞台宽 / unit（元素按 1.3dp 缩小，页宽跟着变宽），
    // 页面里的右缘常量都读 canvas.gridWidth，不能再写死 393。
    final double gridWidth = portraitGridWidth(width, stageScale: stageScale);
    final PortraitCanvas canvas = PortraitCanvas(
      metrics: metrics,
      unit: unit,
      gridWidth: gridWidth,
      height: portraitGridHeight(height, unit),
      dark: dark,
    );
    final List<BasicListItem> items = basicLibraryItems(state);
    final int selected = _selectedRow(state, items);
    final player.PlayerBarState bar = _playerState(state, musicVideo: mvAvailable);
    // 空列/未接入的诚实文案：端口没接上本地集合时不能说「这里本来是空的」。
    final String emptyNotice = state.error.isNotEmpty
        ? state.error
        : (state.status.isNotEmpty
            ? state.status
            : basicLaneEmptyNotice(
                state.selectedLane,
                localCollectionsAvailable: state.localCollectionsAvailable,
                unresolvedLikedIds: state.localUnresolvedLikedIds,
                remote: state.searchRemote,
              ));
    final SirenSong? song = state.song;
    final BasicDirectory? directory = state.directory;
    // Qt `ResponsiveHudLayout.cpp:40-60`：`songPage = m_song && modal.isEmpty() && !lyric && !comments`。
    // 这里必须同样要求 `modal.isEmpty()`——否则从详情页打开的评论/登录/平台/MV
    // 弹层会被歌曲页整个盖住（真机表现：点了「查看评论」，面板收起了但页面没换）。
    final bool songPage = song != null &&
        modal.isEmpty &&
        (state.phase == BasicPhase.detail || state.phase == BasicPhase.lyrics);
    final PortraitPlayer portraitPlayer = PortraitPlayer(
      title: bar.title,
      artist: bar.artist,
      cover: bar.cover,
      hasTrack: bar.hasTrack,
      playing: bar.playing,
      positionMs: bar.positionMs,
      durationMs: bar.durationMs,
    );
    if (modal == 'queue') {
      // Qt compact `queue()`（ResponsiveHudPages.cpp:468-533）：通用页头（只有返回
      // 箭头 + close-modal，没有设置齿轮）+ 内容自 158 起；播放条与底栏由 shell 画
      // （Qt 队列页的底栏 active=""，所以 nav 传 null）。
      paintPortraitShell(
        canvas,
        player: portraitPlayer,
        nav: null,
        header: (PortraitCanvas c) => c.header(
          '播放队列',
          back: true,
          backAction: 'close-modal',
          showSettings: false,
        ),
        content: (PortraitCanvas c, double pageBottom) => paintPortraitQueuePage(
          c,
          title: bar.title,
          artist: bar.artist,
          tracks: _portraitQueueRows(state),
          currentIndex: state.queueIndex,
          mode: state.queueMode,
          modesExpanded: queueModesExpanded,
          // Android/iOS 的 PlatformFeatures::ApplicationVolume 恒 false（见 _playerState）。
          applicationVolume: bar.applicationVolume,
          volume: 0,
          scroll: queueScroll,
        ),
      );
    } else if (songPage) {
      // Qt compact：song() / lyrics() 是两页，共用「档案 + 封面 + 进度 + 传输」骨架。
      _paintPortraitSongPage(
        canvas,
        state,
        song,
        items.length,
        selected,
        ports,
        commentsAvailable: commentsAvailable,
      );
    } else if (modal == 'provider') {
      // Qt compact `providerPage`（ResponsiveHudPages.cpp:612-701）：通用页头
      // （只有返回箭头 + close-modal，没有设置齿轮）+ 内容自 158 起。播放条与底栏
      // 由 shell 画（Qt 平台页的底栏 active=""，所以 nav 传 null）。
      paintPortraitShell(
        canvas,
        player: portraitPlayer,
        nav: null,
        header: (PortraitCanvas c) => c.header(
          '音乐平台',
          back: true,
          backAction: 'close-modal',
          showSettings: false,
        ),
        content: (PortraitCanvas c, double pageBottom) => paintPortraitProviderPage(
          c,
          // Qt `providerCardsState()`：`PlatformFeatures::LocalMusic` 关掉时 `local`
          // 不进列表。过滤在调用方做（页面文档明确不重复判断）。
          providers: localMusicEnabled
              ? providers
              : providers
                  .where((ProviderDescriptor d) => d.id != 'local')
                  .toList(growable: false),
          currentId: providerId,
          accounts: providerAccounts,
          scrollOffset: '',
          userName: providerUserName,
        ),
      );
    } else if (modal == 'comments' && comments != null) {
      // Qt compact 的评论页（ResponsiveHudLayout.cpp:186-205）：与歌词页同级，
      // 页头自己画（`c.header('歌曲评论', back: true, showSettings: false)`）+
      // 「COMMENT ARCHIVE / 评论档案」小标，内容自 158 起。
      // 与 Qt 同一分工：页面不夹取滚动，宿主把 scroll 夹在 [0, maximumScroll]
      // （Qt `ResponsiveHudLayout.cpp:238-244` 同一处夹取）。
      paintPortraitCommentsPage(
        canvas,
        model: comments,
        scroll: commentsScroll,
      );
    } else if (modal == 'login' && loginState != null) {
      // Qt compact 的登录页（NativeHud::loginPanel 的竖屏对应实现）：整页纸色 +
      // 通用页头（返回箭头 + close-modal），内容由 portrait_pages_login 排布。
      paintPortraitLoginPage(
        canvas,
        state: loginState,
        methods: loginMethods,
        providerName: loginProviderName,
        scanHint: loginScanHint,
        deviceNotice: loginDeviceNotice,
        cooldownLabel: loginCooldownLabel,
        smsRetrySeconds: loginSmsRetrySeconds,
      );
    } else if (modal == 'mv' && mv != null) {
      // 竖屏 MV 页（`lib/hud/portrait/portrait_pages_mv.dart`）：Qt 移动端从不进
      // MV（`Qt/src/PlatformFeatures.h:23-27` 的 `MusicVideo = !RHINE_MOBILE && …`），
      // 所以这一屏没有 Qt 版式真值，几何按竖屏 393 网格自拟（页面文件头已写明）。
      paintPortraitMvPage(canvas, model: mv, position: mvPositionMs);
    } else if (modal == 'settings') {
      // Qt compact 的设置是「终端页」：页头（品牌/标题/编号块/校准刻度）+ 内容
      // 由一页铺到 h-144，底下播放条与底栏照旧。内容本身是真实 widget 层
      // （lib/basic/basic_settings_portrait.dart），这里只画 chrome + 页头。
      paintPortraitShell(
        canvas,
        player: portraitPlayer,
        nav: PortraitNav.settings,
        title: '设置',
        code: '03',
        identifier: 'SETTINGS / 终端配置',
      );
    } else if (modal == 'playlist-picker') {
      // Qt compact `music:add-to-playlist` 打开的是通用列表弹层
      // （`NativeHudMusic.cpp:483-486` + `NativeHudModal.cpp` 的列表分支），
      // 393 网格下没有独立版式，这里按同一网格拟一页（页头 + 歌单行 + 空态）。
      paintPortraitPlaylistPicker(
        canvas,
        playlists: pickerPlaylists,
        notice: pickerNotice,
        canCreate: canCreatePlaylist,
      );
    } else if (modal == 'discover') {
      // Qt compact 的发现页是终端页（`ResponsiveHudLayout.cpp:150-176` 的
      // `modal == "discover"` ⇒ `01 DISCOVER / 音乐观察`），内容按
      // `ResponsiveHudPages.cpp:376-470` 的三分支择一。
      final BasicDiscoverSnapshot page = discover ?? BasicDiscoverSnapshot.empty;
      paintPortraitShell(
        canvas,
        player: portraitPlayer,
        nav: PortraitNav.discover,
        content: (PortraitCanvas c, double bottom) => paintPortraitDiscoverPage(
          c,
          tabs: page.tabs,
          tab: page.tab,
          tools: page.tools,
          categories: page.categories,
          categoryPicker: page.categoryPicker,
          entries: page.entries,
          status: page.status,
          more: page.more,
          loadingMore: page.loadingMore,
          scroll: page.scroll,
        ),
      );
    } else if (modal == 'saved') {
      // Qt compact 的 `saved` 是**三态**（`ResponsiveHudLayout.cpp:455-464` 与
      // `ResponsiveHudPages.cpp:845-1010`）：总览（`m_savedOverview`）、喜欢列
      // （`musicCollection == 1`）、歌单列（其它）。总览由
      // `portrait_saved_overview.dart` 按 `library()` 的总览分支实现，
      // 另两列复用收藏页。
      paintPortraitShell(
        canvas,
        player: portraitPlayer,
        nav: null,
        content: (PortraitCanvas c, double bottom) {
          if (savedOverview) {
            // Qt compact `library()` 的总览分支（ResponsiveHudPages.cpp:858-892）：
            // 平台卡 + 「收藏与档案」索引行（四个收藏列 + 播放历史 + 设置 + 创建歌单）。
            paintPortraitSavedOverview(
              c,
              providerName: savedProviderName,
              userName: savedUserName,
              collectionRows: savedOverviewRows,
              showArtists: savedShowArtists,
              canCreatePlaylist: canCreatePlaylist,
              scroll: savedScroll,
            );
          } else if (savedLane == 2) {
            paintPortraitPlaylistsPage(
              c,
              rows: playlistRows,
              selectedIndex: state.selectedLane == 2 ? 0 : -1,
              loading: state.loading,
              notice: savedNotice,
              canCreate: true,
            );
          } else {
            paintPortraitLikesPage(
              c,
              rows: likedRows,
              selectedIndex: state.selectedLane == 1 ? 0 : -1,
              loading: state.loading,
              notice: savedNotice,
            );
          }
        },
      );
    } else if (modal == 'search') {
      // Qt compact `library()` 的 search 分支（ResponsiveHudPages.cpp:941-990）：
      // 检索框 + 四分类 tab + 歌曲分类才有的分组条 + `01 检索结果 INDEX / N` +
      // 结果行。行数据来自 `BasicViewState.searchRows`（分类检索索引的 items，
      // 每项是 Qt `MusicData::item` 形状的 Map），已按分组视图过滤。
      paintPortraitShell(
        canvas,
        player: portraitPlayer,
        nav: PortraitNav.search,
        content: (PortraitCanvas c, double bottom) => paintPortraitSearchKindsPage(
          c,
          query: state.query,
          searchKind: state.searchKind,
          groupBy: state.searchGroup,
          activeGroup: state.searchGroupKey,
          rows: _portraitSearchRows(state),
          total: state.searchTotal,
          status: state.searchStatus.isEmpty ? emptyNotice : state.searchStatus,
          loading: state.loading,
        ),
      );
    } else if (modal == 'plugins' || modal == 'plugin-detail') {
      // Qt compact 插件页：通用页头（不是终端页头）+ 内容区由真实 widget 承担，
      // 播放条与底栏照旧由画布画。Qt 插件页的底栏没有高亮项（active=""），
      // 所以 nav 传 null；返回箭头在列表页关弹层（close-modal）、在详情页回列表
      // （plugin:close-detail）。
      final bool detail = modal == 'plugin-detail';
      paintPortraitShell(
        canvas,
        player: portraitPlayer,
        nav: null,
        header: (PortraitCanvas c) => c.header(
          detail ? '插件详情' : '插件管理',
          back: true,
          backAction: detail ? 'plugin:close-detail' : 'close-modal',
        ),
      );
    } else if (directory != null) {
      // Qt compact `collection()`：目录（歌单/专辑）内页。
      paintPortraitCollectionPage(
        canvas,
        title: basicLibraryTitle(state, providerName: providerName),
        subtitle: _portraitCollectionSubtitle(directory, items.length),
        // 目录封面是真实 URL（siren.mjs:209），像素由 BasicCoverImages 解码；
        // 拿不到就留空槽，不编假图。
        cover: directory.cover,
        rows: <(String, String, String, String)>[
          for (final BasicListItem item in items) (item.title, item.artist, '', item.kind),
        ],
        index: selected,
        canPlayAll: items.isNotEmpty,
        emptyNotice: emptyNotice,
        // 目录内页与主页同一份滚动窗口真值（拖动中的 listPosition 优先）。
        position: listPosition ?? state.listPosition ?? selected.toDouble(),
      );
    } else {
      // 列名随平台走（Qt `registry.columns(provider)`）：插件 manifest 的五列是
      // 「搜索结果 / 喜欢的歌曲 / 我的歌单 / 收藏歌单 / 收藏专辑」，与塞壬不同名。
      final List<int> sourceOrder = state.laneColumns.length == basicSirenColumns.length
          ? basicSirenSourceOrder
          : <int>[for (int lane = 0; lane < state.laneColumns.length; lane++) lane];
      final List<PortraitTab> tabs = <PortraitTab>[
        for (final int lane in sourceOrder)
          if (lane >= 0 && lane < state.laneColumns.length)
            PortraitTab(label: state.laneColumns[lane], lane: lane),
      ];
      paintPortraitHome(
        canvas,
        archive: PortraitArchive(
          tabs: tabs,
          selectedLane: state.selectedLane,
          title: basicLibraryTitle(state, providerName: providerName),
          rows: <PortraitRow>[
            for (final BasicListItem item in items)
              PortraitRow(title: item.title, kind: item.kind),
          ],
          index: selected,
          directory: false,
          canPlayAll: items.isNotEmpty,
          emptyNotice: emptyNotice,
        ),
        player: portraitPlayer,
        nav: PortraitNav.archive,
        listPosition: listPosition,
      );
    }
    // Qt `ResponsiveHudLayout.cpp:270-272`：选项面板是最后一层覆盖
    // （`if (m_songOptionsExpanded && (m_song || m_lyricsPage)) optionsSheet(c, source)`），
    // 所以它在整页画完之后叠上来，且只画 sheet 本身（遮罩不动）。
    if (songOptionsExpanded && (song != null || state.phase == BasicPhase.lyrics)) {
      // 页面 painter 以 `c.finish()`（restore）收尾，会弹掉画布构造时的
      // `save` + `scale(unit, unit)`；这里不补回来，面板就会按逻辑像素画成半尺寸，
      // 命中矩形也跟着错位（真机上表现为「面板画出来了，但按钮点不动」）。
      canvas.ensureScale();
      // 整屏遮罩：Qt `ResponsiveLyrics.cpp:238` 的 `hit({0,118,393,h-118},
      // "mobile:song-options", "收起操作")` 就是"点面板外的任何地方收起"。
      // 先发遮罩命中（后发者优先，所以它必须在按钮热区之后加入？不——命中按
      // append-only 反向遍历，遮罩先加 ⇒ 按钮更晚 ⇒ 按钮优先，符合预期）。
      canvas.hit(
        Rect.fromLTWH(0, portraitSongOptionsMinTop, canvas.gridWidth,
            canvas.height - portraitSongOptionsMinTop),
        'mobile:song-options',
        '收起操作',
      );
      paintPortraitSongOptions(
        canvas,
        actions: _portraitSongOptionsActions(
          state,
          commentsAvailable: commentsAvailable,
          mvAvailable: mvAvailable,
        ),
        detail: songOptionsDetail,
        detailBody: songOptionsDetailBody,
      );
    }
    sink.commands.addAll(canvas.commands);
    sink.hits.addAll(canvas.hits);
    final Map<String, Rect> fields = <String, Rect>{...canvas.fields};
    final bool animating = ports.endFrame();
    _generation += 1;
    return BasicHudFrame(
      generation: _generation,
      commands: sink.commands,
      hits: sink.hits,
      fields: fields,
      animating: animating,
    );
  }

  /// 竖屏页面用的字形度量端口（同一份 `ports`，竖屏与横屏重采样共用）。
  static PortraitMetrics _portraitMetrics(BasicGlyphPorts ports) {
    return PortraitMetrics(
      width: (String value, double size, String weight) => ports.width(value, size, weight),
      wrap: (String value, double limit, double size, String weight) =>
          ports.wrap(value, limit, size, weight),
      bounds: (String value, double size, String weight) {
        final player.GlyphBounds bounds = ports.bounds(value, size, weight);
        return PortraitGlyphBounds(
          x: bounds.x,
          y: bounds.y,
          width: bounds.width,
          height: bounds.height,
        );
      },
    );
  }

  /// 把竖屏专属页面（我的音乐 / 发现 / 加入歌单）重采样后叠进横屏帧。
  ///
  /// 这三页在 Qt 桌面端由 library 模态承载（`NativeHudLibrary.cpp` 的 saved 面板），
  /// 本仓库只实现了 compact 稿。横屏按 852 参考高度等比重采样，页面宽度跟随舞台，
  /// 右缘元素仍然贴边（painter 都读 `canvas.gridWidth`）。
  static void _paintPortraitPageInLandscape(
    _HudSink sink, {
    required BasicGlyphPorts ports,
    required BasicViewState state,
    required double width,
    required double height,
    required bool dark,
    required String modal,
    required int savedLane,
    required bool savedOverview,
    required List<PortraitLikesRow> likedRows,
    required List<PortraitPlaylistRow> playlistRows,
    required String savedNotice,
    required String savedProviderName,
    required String savedUserName,
    required List<PortraitSavedOverviewRow> savedOverviewRows,
    required bool savedShowArtists,
    required double savedScroll,
    BasicDiscoverSnapshot? discover,
    List<(String, String, int)> pickerPlaylists = const <(String, String, int)>[],
    String pickerNotice = '',
    bool canCreatePlaylist = false,
  }) {
    const double referenceHeight = 852;
    final double unit = height / referenceHeight;
    final PortraitCanvas canvas = PortraitCanvas(
      metrics: _portraitMetrics(ports),
      unit: unit,
      gridWidth: width / unit,
      height: referenceHeight,
      dark: dark,
    );
    // 横屏帧没有迷你播放条与底栏，内容一直铺到页面底部再留一点余量。
    canvas.contentBottom = referenceHeight - 40;
    if (modal == 'discover') {
      final BasicDiscoverSnapshot page = discover ?? BasicDiscoverSnapshot.empty;
      paintPortraitDiscoverPage(
        canvas,
        tabs: page.tabs,
        tab: page.tab,
        tools: page.tools,
        categories: page.categories,
        categoryPicker: page.categoryPicker,
        entries: page.entries,
        status: page.status,
        more: page.more,
        loadingMore: page.loadingMore,
        scroll: page.scroll,
      );
    } else if (modal == 'playlist-picker') {
      paintPortraitPlaylistPicker(
        canvas,
        playlists: pickerPlaylists,
        notice: pickerNotice,
        canCreate: canCreatePlaylist,
      );
    } else if (savedOverview) {
      paintPortraitSavedOverview(
        canvas,
        providerName: savedProviderName,
        userName: savedUserName,
        collectionRows: savedOverviewRows,
        showArtists: savedShowArtists,
        canCreatePlaylist: canCreatePlaylist,
        scroll: savedScroll,
      );
    } else if (savedLane == 2) {
      paintPortraitPlaylistsPage(
        canvas,
        rows: playlistRows,
        selectedIndex: state.selectedLane == 2 ? 0 : -1,
        loading: state.loading,
        notice: savedNotice,
        canCreate: true,
      );
    } else {
      paintPortraitLikesPage(
        canvas,
        rows: likedRows,
        selectedIndex: state.selectedLane == 1 ? 0 : -1,
        loading: state.loading,
        notice: savedNotice,
      );
    }
    sink.commands.addAll(canvas.commands);
    sink.hits.addAll(canvas.hits);
  }

  /// 竖屏「歌曲操作 / 歌词操作」面板的按钮表（Qt `ResponsiveLyrics.cpp:246-272`）。
  ///
  /// 歌词页固定四条（local 平台才有第五条 `歌词来源`）；详情页取 `primaryActions`
  /// 去掉播放/喜欢、再加上 `secondaryActions`，末尾按能力补 `官方客户端 ↗` 与
  /// `查看评论`。空 route 的条目 Qt 也会照画（画布会跳过它的热区）。
  static List<(String label, String action)> _portraitSongOptionsActions(
    BasicViewState state, {
    required bool commentsAvailable,
    required bool mvAvailable,
  }) {
    if (state.phase == BasicPhase.lyrics) {
      return <(String, String)>[
        ('歌词提前 0.2s', 'player:lyrics-earlier'),
        ('歌词延后 0.2s', 'player:lyrics-later'),
        ('重置歌词偏移', 'player:lyrics-reset'),
        ('重新查找歌词', 'player:lyrics-retry'),
      ];
    }
    return <(String, String)>[
      ('＋ 加入歌单', 'music:add-to-playlist'),
      ('＋ 加入队列', 'music:enqueue'),
      ('▷ 下一首播放', 'music:play-next'),
      if (commentsAvailable) ('查看评论', 'music:comments'),
      // 动作串由 `MvAction.open`（`lib/domain/mv/mv_controller.dart:662`）定义；
      // hud 层不 import domain，所以这里写字面量并在测试里与 MvAction 对表。
      if (mvAvailable) ('关联 MV', 'mv:open'),
    ];
  }

  /// 竖屏详情页 / 歌词页（Qt compact `ResponsiveHudPages.cpp` 的 `song()` / `lyrics()`）。
  static void _paintPortraitSongPage(
    PortraitCanvas canvas,
    BasicViewState state,
    SirenSong song,
    int total,
    int selected,
    BasicGlyphPorts ports, {
    bool commentsAvailable = false,
  }) {
    // 详情页曲目与播放曲目是**两个身份**（Qt compact `song()` 的
    // `selectedSongIsCurrent`，ResponsiveHudPages.cpp:165）：打开另一首的详情时，
    // 控制带必须服从详情页曲目，不能把在播那首的进度/播放态/传输键搬过来。
    final SirenSong? playingTrack = state.playingTrack;
    final bool current = playingTrack != null && playingTrack.id == song.id;
    if (state.phase == BasicPhase.lyrics) {
      // 歌词页画的就是**正在播放**的那首：标题/艺人/封面取 playingTrack。
      // 取 state.song（选中行）会让从底栏进来的歌词页挂错歌名——歌词属于播放曲目，
      // 标题却属于选中行，是同一类身份串台。
      final SirenSong shown = playingTrack ?? song;
      paintPortraitLyricsPage(
        canvas,
        title: shown.title,
        artist: shown.artist,
        cover: shown.cover,
        playing: state.playing,
        positionMs: state.positionMs,
        durationMs: state.durationMs,
        lines: <(int, String, String)>[
          for (final BasicLyricLine line in state.lyrics)
            (line.startMs.round(), line.text, line.translation),
        ],
        activeLine: state.lyricIndex,
        // 收藏真态：Qt 用 `selectedLiked`（`NativeHud.cpp:472`），这里走同一个
        // 字形端口，详情页/歌词页/沉浸条三处不会出现两套答案。
        liked: ports.songLiked?.call((playingTrack ?? song).id) ?? false,
      );
      return;
    }
    paintPortraitSongPage(
      canvas,
      title: song.title,
      artist: song.artist,
      album: song.album,
      kind: 'song',
      stamp: total <= 0 ? '' : _portraitStamp(selected, total),
      cover: song.cover,
      current: current,
      // playing/buffering 传**播放器真值**，由画布按 current 决定显不显示：
      // 非当前曲目在画布内部会显示「尚未播放」并画空进度。
      playing: state.playing,
      buffering: state.buffering,
      // 收藏状态来自本机集合（`BasicController.isLiked`），不再写死 false：
      // 竖屏详情页的心是唯一能看见「已喜欢」的地方（Qt `NativeHud.cpp:472` 的
      // `selectedLiked` 同义）。
      favourite: ports.songLiked?.call(song.id) ?? false,
      positionMs: state.positionMs,
      // 非当前曲目拿不到 native 的时长（那是播放器在报的），回落曲库里的本曲目时长；
      // 曲库阶段该值可能还是 0，画布会显示 00:00，不编造数字。
      durationMs: current ? state.durationMs : song.durationMs,
      lyricPreview: _portraitLyricPreview(state),
      // 歌词入口只在当前曲目上出现：state.lyrics 是播放曲目的歌词。
      lyricsAvailable: current && state.lyrics.isNotEmpty,
    );
  }

  /// 竖屏队列页的行投影：标题/艺人/时长 + 封面 key，与横屏面板同一份 [state.queue]。
  static List<PortraitQueueRow> _portraitQueueRows(BasicViewState state) {
    return <PortraitQueueRow>[
      for (final SirenSong song in state.queue)
        (
          title: song.title,
          artist: song.artist,
          // Qt queue() 用 MusicData::time(track)：毫秒 → mm:ss，<= 0 显示「暂无」。
          stamp: queue_modal.queueModalTime(_queueModalTrack(song)),
          image: song.cover,
        ),
    ];
  }

  /// [SirenSong] → 横屏面板条目（时长取毫秒，供 `queueModalTime` 同口径取整）。
  static queue_modal.QueueModalTrack _queueModalTrack(SirenSong song) =>
      queue_modal.QueueModalTrack(
        title: song.title,
        artist: song.artist,
        duration: song.durationMs,
      );

  /// 横屏播放队列面板：外壳（遮罩 + 836 面板底 + 返回按钮）走共享 [ModalShell]，
  /// 内容走 `queue_modal.renderQueueModal`。
  ///
  /// Qt 对应 NativeHudModal.cpp:163-186 的 `modal == "player"` 分支：全舞台遮罩 +
  /// `{left,122,width,836}` 面板底，然后 `playerPanel()` 直接画卡片，**不走标题区**。
  static void _paintQueueModal(
    _HudSink sink,
    BasicGlyphPorts ports,
    BasicViewState state,
    double width,
    double height,
    bool dark,
    int queueOffset,
  ) {
    final int count = state.queue.length;
    final int offset = queueOffset.clamp(0, queue_modal.queueModalMaximumOffset(count));
    final SirenSong? playing = state.playingTrack;
    final _QueueModalGlyphs glyphs = _QueueModalGlyphs(ports);
    // 外壳（遮罩 + 面板底 + 返回按钮）走共享 ModalShell；面板矩形由它算
    // （Qt NativeHud::modalBounds 通用分支 = 顶 122 / 高 836 / 居中 1260）。
    // 内容用真实矩形重算卡片：queue_modal 内部再按 bounds.x+53 / width-106 收缩。
    final ModalShellResult result = ModalShell(
      sink: sink,
      text: ports,
      spec: ModalShellSpec(
        modalId: kModalShellPlayerModal,
        stageWidth: width,
        stageHeight: kModalShellStageHeight,
        dark: dark,
        content: (ModalShellBody body) {
          final ModalShellBounds bounds = body.bounds;
          final queue_modal.QueueModalDrawing drawing = queue_modal.renderQueueModal(
            queue_modal.QueueModalState(
              bounds: queue_modal.QueueModalRect(
                bounds.left,
                bounds.top,
                bounds.width,
                bounds.height,
              ),
              tracks: <queue_modal.QueueModalTrack>[
                for (final SirenSong song in state.queue) _queueModalTrack(song),
              ],
              // Qt 的 current 是空对象时才显示「暂无播放歌曲」（PlaybackQueueCard.cpp:51）。
              current: playing == null ? null : _queueModalTrack(playing),
              cover: playing?.cover ?? '',
              mode: state.queueMode,
              status: state.playerStatus,
              currentIndex: state.queueIndex,
              offset: offset,
              playing: state.playing,
              dark: dark,
            ),
            glyphs,
          );
          for (final List<Object?> command in drawing.commands) {
            body.sink.op(command);
          }
          // 卡片命中是六键 map（无 fixed）：解码成 HudHit 后并入外壳的命中表，
          // 保持与 Qt hits 相同的 append 顺序。
          for (final HudHit hit in decodeHudHits(drawing.hits).hits) {
            body.hits.hit(hit);
          }
        },
      ),
    ).build();
    sink.hits.addAll(result.hits);
  }

  /// 横屏评论面板（Qt `NativeHudComments.cpp` 的 `commentsPanel(x, usable)`，
  /// 唯一调用点 `Qt/src/NativeHudDetail.cpp:45-100`：x = width*0.56、
  /// usable = width - x - 59，走 save/alpha/.../restore 自己管透明度）。
  static void _paintCommentsPanel(
    _HudSink sink,
    BasicGlyphPorts ports,
    PortraitCommentsModel model,
    double width,
    double height,
    bool dark,
    double scroll,
  ) {
    final double x = width * 0.56;
    final double usable = width - x - 59;
    final comments_modal.CommentPanelDrawing drawing = comments_modal.paintCommentsPanel(
      _commentPanelModel(model, x: x, width: usable, dark: dark),
      _CommentPanelGlyphs(ports),
      scroll: comments_modal.cmtClampPanelScroll(scroll, _commentsContentBottom),
    );
    _commentsContentBottom = drawing.contentBottom;
    sink.addDrawing(drawing.commands, drawing.hits);
  }

  /// 上一帧评论内容的总高（Qt 成员 `commentsContentBottom`，每帧由面板回存，
  /// 下一帧据此夹取滚动；不存会让越滚可滚范围越小、滚轮抽搐）。
  static double _commentsContentBottom = 0;

  /// 领域层的竖屏视图模型 → 横屏面板模型（字段一一同名，只是面板多了
  /// x/width/dark 三个宿主上下文）。
  static comments_modal.CommentPanelModel _commentPanelModel(
    PortraitCommentsModel model, {
    required double x,
    required double width,
    required bool dark,
  }) {
    return comments_modal.CommentPanelModel(
      x: x,
      width: width,
      dark: dark,
      status: model.status,
      message: model.message,
      sort: model.sort,
      totalLabel: model.totalLabel,
      hasMore: model.hasMore,
      loadingMore: model.loadingMore,
      sourceName: model.sourceName,
      sourceLabel: model.sourceLabel,
      providerId: model.providerId,
      items: <comments_modal.CommentPanelItem>[
        for (final PortraitCommentRow row in model.items)
          comments_modal.CommentPanelItem(
            id: row.id,
            nickname: row.nickname,
            content: row.content,
            avatarKey: row.avatarKey,
            timeLabel: row.timeLabel,
            likedLabel: row.likedLabel,
            replyCount: row.replyCount,
            expanded: row.expanded,
            inlineReplies: <comments_modal.CommentPanelReply>[
              for (final PortraitCommentReply reply in row.inlineReplies)
                _commentPanelReply(reply),
            ],
            replies: <comments_modal.CommentPanelReply>[
              for (final PortraitCommentReply reply in row.replies) _commentPanelReply(reply),
            ],
            repliesExpanded: row.repliesExpanded,
            repliesHasMore: row.repliesHasMore,
            repliesLoading: row.repliesLoading,
            repliesError: row.repliesError,
          ),
      ],
    );
  }

  static comments_modal.CommentPanelReply _commentPanelReply(PortraitCommentReply reply) =>
      comments_modal.CommentPanelReply(
        id: reply.id,
        nickname: reply.nickname,
        content: reply.content,
        replyTo: reply.replyTo,
      );

  /// 横屏 MV 弹层（Qt 移动端从不进 MV，几何按桌面 `MvWindow.qml` 的等价实现）。
  static void _paintMvModal(
    _HudSink sink,
    BasicGlyphPorts ports,
    MvPanelModel model,
    double width,
    double positionMs,
    bool dark,
  ) {
    final ModalShellResult result = mv_modal.MvModal(
      width: width,
      dark: dark,
      model: model,
      position: positionMs,
      pictureOffsetMs: positionMs.round(),
    ).build(sink, ports);
    sink.hits.addAll(result.hits);
  }

  /// 横屏检索弹层：面板外壳 + 检索条 + 分类/分组 tab + 结果行 + 页脚。
  ///
  /// 行来自 [BasicViewState.searchRows]（竖屏检索页同一份投影），因此横屏不再依赖
  /// `basicLibraryItems` 的 lane 投影——远端检索时 lane 里没有命中行，这就是之前
  /// 横屏检索列表恒空的原因。
  static void _paintSearchModal(
    _HudSink sink,
    BasicGlyphPorts ports,
    BasicViewState state,
    double width,
    bool dark,
    double scroll,
    bool localMusicEnabled,
  ) {
    final List<search_panel.SearchPanelRow> rows = <search_panel.SearchPanelRow>[
      for (final PortraitSearchKindsRow row in _portraitSearchRows(state))
        (title: row.title, detail: row.artist, stamp: row.stamp, action: row.action),
    ];
    final ModalShellResult result = search_panel.SearchPanel(
      width: width,
      dark: dark,
      query: state.query,
      searchKind: state.searchKind,
      groupBy: state.searchGroup,
      status: state.searchStatus,
      total: state.searchTotal,
      rows: rows,
      localMusic: localMusicEnabled,
      scroll: scroll,
    ).build(sink, ports);
    sink.hits.addAll(result.hits);
  }

  /// 横屏登录弹层（Qt `NativeHud::loginPanel`，`NativeHudLibrary.cpp:271-330`）。
  static void _paintLoginModal(
    _HudSink sink,
    BasicGlyphPorts ports,
    LoginState state,
    List<ProviderLoginMethod> methods,
    String providerName,
    String scanHint,
    String deviceNotice,
    String cooldownLabel,
    double width,
    bool dark,
  ) {
    final login_modal.LoginModalFrame frame = login_modal.LoginModal(
      textPort: ports,
      stageWidth: width,
      state: state,
      text: <String, String>{
        if (scanHint.isNotEmpty) 'scanHint': scanHint,
        if (deviceNotice.isNotEmpty) 'deviceNotice': deviceNotice,
      },
      methods: methods,
      cooldownLabel: cooldownLabel,
      title: login_modal.loginModalTitle(providerName),
      subtitle: login_modal.loginModalSubtitle(scanHint),
      dark: dark,
    ).build();
    sink.commands.addAll(frame.commands);
    sink.hits.addAll(frame.hits);
  }

  /// 横屏平台弹层（Qt `NativeHud::platformPanel`，`NativeHudModal.cpp:400-419`）。
  static void _paintProviderModal(
    _HudSink sink,
    BasicGlyphPorts ports,
    List<ProviderDescriptor> providers,
    String providerId,
    Map<String, ProviderAccount?> accounts,
    double width,
    bool dark,
    bool localMusicEnabled,
  ) {
    final provider_modal.ProviderModalFrame frame = provider_modal.ProviderModal(
      textPort: ports,
      stageWidth: width,
      dark: dark,
      opacity: 1,
      offset: 0,
      currentProvider: providerId,
      credentials: <String>{
        for (final MapEntry<String, ProviderAccount?> entry in accounts.entries)
          if (entry.value?.loggedIn ?? false) entry.key,
      },
      localMusicEnabled: localMusicEnabled,
      entries: providers.isEmpty
          ? null
          : <provider_modal.ProviderModalEntry>[
              for (final ProviderDescriptor descriptor in providers)
                if (localMusicEnabled || descriptor.id != 'local')
                  provider_modal.ProviderModalEntry(
                    id: descriptor.id,
                    name: descriptor.name,
                    label: descriptor.label,
                    detail: descriptor.detail,
                  ),
            ],
    ).build();
    sink.commands.addAll(frame.commands);
    sink.hits.addAll(frame.hits);
  }

  /// 竖屏序号（Qt 的 `pad()`：两位，超过 99 自然变三位）。
  static String _portraitStamp(int index, int total) {
    final String left = (index + 1).toString().padLeft(2, '0');
    final String right = total.toString().padLeft(2, '0');
    return '$left / $right';
  }

  static String _portraitLyricPreview(BasicViewState state) {
    final int index = state.lyricIndex;
    if (index >= 0 && index < state.lyrics.length) {
      return state.lyrics[index].text;
    }
    return state.lyrics.isEmpty ? '' : state.lyrics.first.text;
  }

  /// 目录内页副标：真实曲目数 + 类型（Qt `collection()` 的 eyebrow 行语义）。
  static String _portraitCollectionSubtitle(BasicDirectory directory, int visible) {
    final int count = visible > 0 ? visible : directory.trackCount;
    final String kind = switch (directory.kind) {
      'playlist' => '歌单',
      'album' => '专辑',
      'artist' => '歌手',
      'collection' => '收藏',
      _ => '',
    };
    if (count <= 0) {
      return kind;
    }
    return kind.isEmpty ? '共 $count 首' : '共 $count 首 · $kind';
  }

  /// 选中行（空列时 0）：与横屏 `_paintLibrary` 同一份列表真值。
  static int _selectedRow(BasicViewState state, List<BasicListItem> items) {
    if (items.isEmpty) {
      return 0;
    }
    return basicSelectedItemIndex(state, items).clamp(0, items.length - 1).toInt();
  }

  static void _paintLibrary(
    _HudSink sink,
    BasicGlyphPorts ports,
    BasicViewState state,
    double width, {
    required bool portrait,
    double? listPosition,
    bool trackListMode = true,
    String providerId = sirenProvider,
    String providerName = basicLibraryName,
    bool isSirenProvider = true,
  }) {
    final List<BasicListItem> items = basicLibraryItems(state);
    final int rawSelected = basicSelectedItemIndex(state, items);
    final int selected = items.isEmpty ? 0 : rawSelected.clamp(0, items.length - 1).toInt();
    final String currentId = items.isEmpty ? '' : _currentId(state, items[selected]);
    final String currentTitle = items.isEmpty ? '' : items[selected].title;
    final String currentArtist =
        items.isEmpty ? '' : _currentArtist(state, items[selected]);

    if (state.phase == BasicPhase.detail && state.album != null) {
      hudControl(sink, ports, '← 返回曲库', 59, 211, 280, 'back', dark: state.dark);
    }

    HudArchivePage(sink, ports, dark: state.dark).archive(
      width: width,
      s: HudArchiveState(
        libraryName: basicLibraryTitle(state, providerName: providerName),
        libraryIndex: selected,
        libraryTotal: items.length,
        // 真实列：Qt `selectedLane` / `sourceOrder().indexOf(selectedLane)` /
        // columns.size()（Qt/src/NativeHud.cpp:479-490 的 COLLECTION xx / 05）。
        selectedLane: state.selectedLane.clamp(0, basicSirenColumns.length - 1).toInt(),
        laneCount: basicSirenColumns.length,
        sourceOrderIndex: basicSourceOrderIndex(state.selectedLane),
        provider: providerId,
        isLocal: false,
        isSiren: isSirenProvider,
        directory: state.directory != null,
        directoryKind: state.directory?.kind,
        uid: '',
        restoringAccount: false,
        sourceLoading: state.loading,
        // 列表形式真值由 surface 持有（Tab Mode 切换），这里只投影当前值：
        // 绘制分支（列表 / 单条面板）与 Tab 文案的粗细都读它，不再写死 true。
        trackListMode: trackListMode,
        current: ArchiveItem(
          id: currentId,
          title: currentTitle.isEmpty ? sirenUnknownTitle : currentTitle,
          artist: currentArtist,
          // 真实条目类型：专辑列（lane 4）的行是 album，不当 song 冒充。
          kind: items.isEmpty ? 'song' : items[selected].kind,
        ),
        libraryItemsEmpty: items.isEmpty,
        libraryItemsLength: items.length,
        selectedPhysicalRow: selected,
        sourceMessage: state.status,
      ),
      drawTrackList: (double _, HudArchiveState _) {},
      drawEmpty: (double _, HudArchiveState _) {},
      // Qt NativeHudController.cpp:945-948 supportsTrackList()：只有当前条目是
      // 曲目（kind == "song"）时才给 Tab Mode 按钮。原来这里恒 false，按钮因此
      // 永远不出现。
      supportsTrackList: (HudArchiveState s) => s.current?.kind == 'song',
    );

    if (items.isEmpty) {
      hudText(
        sink,
        state.error.isNotEmpty
            ? state.error
            // 空列文案按列区分（账号列不假装已加载、检索列提示输入关键词）。
            : (state.status.isEmpty
                ? basicLaneEmptyNotice(
                    state.selectedLane,
                    // 「喜欢/歌单」列的空态必须同时看端口可用性与未解析条数：
                    // 端口没接上 ≠ 收藏是空的（basic_models.dart:531-538）。
                    localCollectionsAvailable: state.localCollectionsAvailable,
                    unresolvedLikedIds: state.localUnresolvedLikedIds,
                    remote: state.searchRemote,
                  )
                : state.status),
        59,
        500,
        20,
        dark: state.dark,
      );
      if (state.error.isNotEmpty || !state.loading) {
        hudControl(sink, ports, '重试', 59, 540, 200, 'retry', dark: state.dark);
      }
      return;
    }

    final List<ruler.TrackListItem> values = <ruler.TrackListItem>[
      for (final BasicListItem item in items) ruler.TrackListItem(title: item.title, kind: item.kind),
    ];
    // Tab Mode 关掉列表形式、且当前条目是曲目时，右栏整块交给 archive() 的
    // 单条面板（标题 / ID / 「查看歌曲详情 →」），曲目列不再叠画——这就是
    // 「真实形式切换」。专辑/歌单等非曲目条目在 Qt 里本来就只走单条面板，
    // 曲目列照旧绘制，不因这个开关消失（否则专辑列会整块变空）。
    final bool singleItemForm = !trackListMode && items[selected].kind == 'song';
    void drawList(_HudSink target) {
      ruler.HudTrackRuler(target, ports, dark: state.dark, glyphBounds: ports).archiveTrackList(
        x: basicNavigationLeft(width),
        width: width,
        values: values,
        selected: selected,
        selectedTitle: currentTitle,
        /// 滚动窗口是连续量（条目单位）：静止时由 state.listPosition 决定
        /// （= 选中行），拖动时由手指位移临时覆盖。position 与 selected 分开传，
        /// 高亮永远跟选中走，不跟窗口走。外部状态没给窗口时跟随选中（旧行为）。
        position: listPosition ?? state.listPosition ?? selected.toDouble(),
      );
    }

    if (portrait) {
      if (!singleItemForm) sink.shifted(0, basicPortraitListShift, drawList);
    } else {
      if (!singleItemForm) drawList(sink);
    }

    if (state.error.isNotEmpty) {
      hudText(sink, state.error, 59, portrait ? 1120 : 40, 16, dark: state.dark);
    }
  }

  /// 选中行的歌手（Qt NativeHud.cpp:439-442 的 item.artist）：跟随高亮行自己的源，
  /// 不再借用 state.song/state.album（混排时两者可能指向别的条目）。
  static String _currentArtist(BasicViewState state, BasicListItem item) {
    if (item.kind == 'album' && item.index >= 0 && item.index < state.albums.length) {
      return state.albums[item.index].artist;
    }
    if (item.kind == 'song' && item.index >= 0 && item.index < state.songs.length) {
      return state.songs[item.index].artist;
    }
    return '';
  }

  /// 测试入口：右栏高亮行的身份 id（与绘制/封面共用同一个函数）。
  @visibleForTesting
  static String currentIdForTest(BasicViewState state, BasicListItem item) =>
      _currentId(state, item);

  static String _currentId(BasicViewState state, BasicListItem item) {
    if (item.kind == 'album' && item.index < state.albums.length) {
      return state.albums[item.index].id;
    }
    // 歌单行的身份来自行自己（BasicListItem.id），不能拿 state.songs[item.index] 顶——
    // 「我的歌单」列里没有曲目，按下标回落到曲库会给出另一首歌的 id（132R D2）。
    if (item.kind == 'playlist') {
      return item.id;
    }
    if (item.kind == 'song' && item.index < state.songs.length) {
      return state.songs[item.index].id;
    }
    return '';
  }

  static detail.SongDetailState _detailState(
    BasicViewState state, {
    String providerId = sirenProvider,
    String providerName = basicLibraryName,
    bool isSiren = true,
  }) {
    final SirenSong? song = state.song;
    // 平台 id 可能没被宿主传下来（默认空串）：身份串必须是 `<provider>:<id>`，
    // 空 provider 会让 `item.identity`（`:s1`）与播放身份（`siren:s1`）不等，
    // 歌词页于是被判成「不是同一首歌」而不走歌词面板。
    final String identityProvider = providerId.isEmpty ? sirenProvider : providerId;
    return detail.SongDetailState(
      provider: identityProvider,
      officialPlayback: false,
      item: song == null
          ? null
          : detail.SongDetailItem(
              id: song.id,
              kind: 'song',
              title: song.title.isEmpty ? sirenUnknownTitle : song.title,
              artist: song.artist,
              artists: song.artist.isEmpty ? const <String>[] : <String>[song.artist],
              album: song.album,
              durationMs: song.durationMs,
              provider: identityProvider,
            ),
      dark: state.dark,
      lyricsMode: state.phase == BasicPhase.lyrics,
      isSiren: isSiren,
      providerName: providerName,
      uid: '',
      detailLoading: state.loading,
      player: detail.SongDetailPlayerState(
        currentIdentity: song == null ? null : '$identityProvider:${song.id}',
        loading: state.buffering || state.loading,
        failed: state.playbackError.isNotEmpty,
      ),
      tracks: <detail.SongDetailTrack>[
        for (final SirenSong item in state.queue)
          detail.SongDetailTrack(
            id: item.id,
            title: item.title,
            artist: item.artist,
            durationMs: item.durationMs,
          ),
      ],
    );
  }

  static lyrics.LyricsPanelModel _lyricsModel(
    BasicViewState state,
    double x,
    double usable, {
    String providerId = sirenProvider,
  }) {
    final SirenSong? song = state.song;
    final BasicLyricsDocument document = BasicLyricsDocument(
      lines: state.lyrics,
      offsetMs: 0,
      plainText: '',
      timed: state.lyrics.isNotEmpty,
    );
    return lyrics.LyricsPanelModel(
      x: x,
      width: usable,
      title: song?.title ?? '',
      artist: song?.artist ?? '',
      document: document.toLyricsDocument(),
      index: state.lyricIndex,
      status: state.lyricStatus,
      message: state.lyricMessage,
      seekable: state.durationMs > 0,
      provider: providerId,
      isLocal: false,
      dark: state.dark,
    );
  }

  static player.PlayerBarState _playerState(BasicViewState state, {bool musicVideo = false}) {
    // 播放条只报**真正在播**的曲目（state.playingTrack），不拿选中曲目冒充：
    // 选中可以没有播放，播放条不该显示一首没在播的歌。
    final SirenSong? song = state.playingTrack;
    return player.PlayerBarState(
      title: song?.title ?? '',
      artist: song?.artist ?? '',
      album: song?.album ?? '',
      // 封面必须带上：竖屏 shell 的播放条左槽、横屏的 PlayerBar 封面都读这个字段；
      // 少传一次，整条播放条的封面就永远是空槽（Qt `PlayerBar.cpp` 的 cover 同理）。
      cover: song?.cover ?? '',

      status: state.playbackError.isNotEmpty ? state.playbackError : state.playerStatus,
      positionMs: state.positionMs,
      durationMs: state.durationMs,
      playing: state.playing,
      loading: state.buffering || state.loading,
      failed: state.playbackError.isNotEmpty,
      hasTrack: song != null,
      seekable: state.durationMs > 0,
      applicationVolume: false,
      // 横屏播放条的 MV 按钮（Qt `PlayerBar.cpp:277-282`）：Qt 用
      // `PlatformFeatures::MusicVideo`（Android 恒假，所以主线在手机上从不画这个键），
      // 本仓库的 MV 已经原生可播（`video_player`），所以改按平台 descriptor 的
      // `capabilities.mv` 决定，与竖屏「更多 → 关联 MV」用同一个判据。
      musicVideo: musicVideo,
    );
  }
}

/// 3D 场景在 stage 坐标里的占位矩形（绘制与命中共用同一套 stage 约定）：
///  - 横屏：整窗（0,0,width,height）。Qt 的 Engine::resize 把场景按
///    `width / (height / 1080)`、1080 高舞台算投影（Qt/src/Engine.cpp:841-849），
///    也就是原 Qt 的 1728x1080 整幅；只给左栏会让 QQuickView 变成比 1 比 1 左右的
///    竖长视口，归档被压扁、详情抽出的唱片被裁。右栏文字可读性由 HudChrome 的
///    archiveMask 负责（本文件 :75 `suppressMask: false`），不是靠缩小矩形；
///    984 只是 HUD 内容带的高度（Qt/src/NativeHud.cpp:324-325 `clip(0, 0, width,
///    984)`），不是场景视口——把它当场景矩形会把 1080 高的舞台压成 984/1080 的
///    比例，再靠改 fov/eye 去"修"，那是掩盖视口错，不是修；

///  - 竖屏：上半屏（`height / 2`）。列表从同一条分割线开始
///    （[portraitListTop] = `h * .5`），3D 与列表各占一半。
///
/// 只有尺寸退化（<320）时不挂载；是否选中曲目、是否已联网都不参与判断。
Rect? basicSceneStageRect({
  required bool portrait,
  required double width,
  required double height,
}) {
  final Rect rect = portrait
      ? Rect.fromLTWH(0, 0, width, height * .5)
      : Rect.fromLTWH(0, 0, width, height);
  if (rect.width < 320 || rect.height < 320) {
    return null;
  }
  return rect;
}

/// 曲目列在 stage 坐标里的手势区域（拖动/点选只在这块参与手势竞技场）。
///
/// 常量取自 ruler 自己的裁剪窗口（`ruler.trackRulerTitleY` / `ruler.trackRulerWindowTop`
/// / `ruler.trackRulerWindowHeight`），绘制与手势共用一处，手势层不再自己拍一套坐标。
/// 竖屏窗口上沿就是带顶 [basicPortraitListOffset]（拿不到可视高度时的兜底）——与
/// [basicPortraitListShift] 同一个
/// 换算，绘制平移多少、命中就从哪里开始。
Rect basicLibraryListStageRect({
  required bool portrait,
  required double width,
  double? height,
  double stageScale = 0,
}) {
  // 竖屏 compact 版：列表区就是 1:1 分割线以下的整个下半屏（到播放条上沿），
  // 不再只算四行；绘制、拖动/点选与 ownership 共用这一份高度。
  if (portrait && height != null) {
    final double unit = portraitUnit(width, stageScale: stageScale);
    final double gridHeight = portraitGridHeight(height, unit);
    final double top = portraitListTop(gridHeight);
    final double bottom = math.max(top, gridHeight - portraitFooterHeight);
    return Rect.fromLTWH(
      0,
      top * unit,
      portraitGridWidth(width, stageScale: stageScale) * unit,
      (bottom - top) * unit,
    );
  }
  final double rawLeft = basicNavigationLeft(width) - 4;
  final double left = rawLeft < 0 ? 0 : rawLeft;
  final double right = width < left ? left : width;
  return Rect.fromLTWH(
    left,
    portrait ? basicPortraitListOffset : ruler.trackRulerWindowTop,
    right - left,
    ruler.trackRulerWindowHeight,
  );
}

/// HUD 自己的触摸区域（stage 坐标，闭区间）：每个命中形状（含 android 的触控
/// 余量，口径与 [HitLayer.effectiveRect] 同一处）＋曲目列矩形。
///
/// 这是「谁消费这条指针」的唯一真值：HUD 手势层用它决定 hitTest，原生 raw
/// pointer 适配层也必须用它在 **down 时**决定 ownership（命中这里＝HUD 消费整条
/// 指针序列，不转发给 Qt；否则＝场景消费，转发 Qt 并捕获到终止事件）。
///
/// 与 [BasicHudSurface] 共用同一个 [frame]：绘制、点选、ownership 三者不会各自
/// 推导出不同的命中地图。坐标空间只有一种——舞台坐标（横屏 0..width / 0..984，
/// 竖屏 0..1080 见 [basicSceneStageRect]），不做第二次换算。
List<Rect> basicHudRegionRects(
  BasicHudFrame frame, {
  required StageGeometry geometry,
  required bool android,
  required bool portrait,
  required double width,
  double? height,
  double stageScale = 0,
  Rect? directTouchStageRect,
}) {
  return <Rect>[
    ...basicHudHitStageRects(frame, geometry: geometry, android: android),
    basicLibraryListStageRect(
      portrait: portrait,
      width: width,
      height: height,
      stageScale: stageScale,
    ),
    // 资料库列表页：左侧 3D 直触区也归 HUD（整串指针由 HUD 消费，3D 层不再
    // 二次解释这条手势）。非列表阶段/尺寸退化时传 null，行为与扩展前一致。
    ?directTouchStageRect,
  ];
}

/// HUD 自己画出来的命中形状在舞台坐标里的矩形（含 android 触控余量）。
/// 与 [basicHudRegionRects] 共用同一份口径；扩展的手势域要扣掉这些控件。
List<Rect> basicHudHitStageRects(
  BasicHudFrame frame, {
  required StageGeometry geometry,
  required bool android,
}) {
  final HitLayer layer = HitLayer(geometry: geometry, android: android);
  return <Rect>[for (final HudHit hit in frame.hits) layer.effectiveRect(hit)];
}

/// 同上，但自己起一帧：给不持有 [frame] 的调用方（原生适配层的 ownership
/// 判定、测试）用。命中地图仍然只有一份来源（[BasicHudFrame.build]）。
List<Rect> basicHudOwnedStageRects({
  required BasicViewState state,
  required BasicGlyphPorts ports,
  required StageGeometry geometry,
  required double width,
  required double height,
  required bool portrait,
  bool android = false,
  double? listPosition,
  Rect? directTouchStageRect,
  bool trackListMode = true,
}) {
  final BasicHudFrame frame = BasicHudFrame.build(
    state: state,
    ports: ports,
    width: width,
    height: height,
    portrait: portrait,
    listPosition: listPosition,
    trackListMode: trackListMode,
  );
  return basicHudRegionRects(
    frame,
    geometry: geometry,
    android: android,
    portrait: portrait,
    width: width,
    directTouchStageRect: directTouchStageRect,
  );
}

/// 这条 stage 坐标的指针是否归 HUD 消费（闭区间，与 [HitLayer.containsClosed]
/// 同一约定：右/下边界也算命中）。
bool basicHudOwnsStagePoint(
  Offset stagePoint, {
  required List<Rect> regions,
}) {
  for (final Rect rect in regions) {
    if (stagePoint.dx >= rect.left &&
        stagePoint.dx <= rect.right &&
        stagePoint.dy >= rect.top &&
        stagePoint.dy <= rect.bottom) {
      return true;
    }
  }
  return false;
}

/// HUD 手势层：只在 [regions] 给的矩形内参与命中，矩形外返回 false。
///
/// 这是“不抢 Qt 触摸”的关键：Stack 命中链在返回 true 的子节点处停下，旧实现用
/// `Positioned.fill` + translucent 的 GestureDetector 恒返回 true，于是 Qt 的
/// PlatformView 永远收不到 touch（唱片区域左右拖动不到 Qt 的机制原因）。
/// 现在只有 HUD 自己画出来的命中形状（含 android 的 16 stage 单位触控余量）和
/// 曲目列矩形参与手势，其余位置的触摸原样下探给 PlatformView。
class _HudGestureRegion extends SingleChildRenderObjectWidget {
  const _HudGestureRegion({required this.regions, required Widget super.child});

  final List<Rect> regions;

  @override
  _RenderHudGestureRegion createRenderObject(BuildContext context) =>
      _RenderHudGestureRegion(regions);

  @override
  void updateRenderObject(BuildContext context, _RenderHudGestureRegion renderObject) {
    renderObject.regions = regions;
  }
}

class _RenderHudGestureRegion extends RenderProxyBox {
  _RenderHudGestureRegion(this.regions);

  List<Rect> regions;
  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) {
    for (final Rect rect in regions) {
      // 闭区间：与 HitLayer.containsClosed 同一约定（右/下边界也算命中）。
      if (position.dx >= rect.left &&
          position.dx <= rect.right &&
          position.dy >= rect.top &&
          position.dy <= rect.bottom) {
        return super.hitTest(result, position: position);
      }
    }
    return false;
  }
}

/// 只允许从曲目列开始的竖直拖动（其它位置不参与竞技场，也就不会跟 Qt 抢手势）。
class _LibraryDragRecognizer extends VerticalDragGestureRecognizer {
  _LibraryDragRecognizer({super.debugOwner}) : allows = null;

  bool Function(Offset local)? allows;

  /// 抬手事件的毫秒时间戳。DragEndDetails 不带时间，而 Qt 的 releaseVelocity 要用
  /// 它判断「抬手前是否已经停手 >80ms」（停手再抬手不该起惯性）。
  Duration? releaseStamp;

  @override
  void handleEvent(PointerEvent event) {
    if (event is PointerUpEvent) {
      releaseStamp = event.timeStamp;
    }
    super.handleEvent(event);
  }

  @override
  bool isPointerAllowed(PointerEvent event) {
    final bool Function(Offset local)? check = allows;
    if (check != null && !check(event.localPosition)) {
      return false;
    }
    return super.isPointerAllowed(event);
  }
}

/// 命中/绘制共用外壳：CustomPaint 只重放本帧命令，手势层只解析命中。
class BasicHudSurface extends StatefulWidget {
  const BasicHudSurface({
    super.key,
    required this.state,
    required this.ports,
    required this.onAction,
    this.onFieldTap,
    this.onFields,
    this.onLibraryScroll,
    this.onLibraryScrollUpdate,
    this.geometry,
    this.stage,
    this.sceneKey,
    this.archiveMaskStrength = 0, // = HudChrome.defaultArchiveMaskStrength
    this.trackListMode = true,
    this.onTrackListModeChanged,
    this.sceneSettings,
    this.modal = '',
    this.queueOffset = 0,
    this.queueScroll,
    this.queueModesExpanded = false,
    this.plugins,
    this.pluginDetail,
    this.pluginDetailEnabled = true,
    this.pluginDetailUserInstalled = true,
    this.pluginDetailCanRollback = false,
    this.pluginMessage = '',
    this.songOptionsExpanded = false,
    this.commentsAvailable = false,
    this.mvAvailable = false,
    this.songOptionsDetail = '',
    this.songOptionsDetailBody = '',
    this.providers = const <ProviderDescriptor>[],
    this.providerId = '',
    this.providerName = '',
    this.isSirenProvider = true,
    this.providerAccounts = const <String, ProviderAccount?>{},
    this.providerUserName = '',
    this.localMusicEnabled = true,
    this.comments,
    this.commentsScroll = 0,
    this.loginState,
    this.loginMethods = const <ProviderLoginMethod>[],
    this.loginProviderName = '',
    this.loginScanHint = '',
    this.loginDeviceNotice = '',
    this.loginCooldownLabel = '',
    this.loginSmsRetrySeconds = 0,
    this.savedLane = 0,
    this.savedOverview = true,
    this.likedRows = const <PortraitLikesRow>[],
    this.playlistRows = const <PortraitPlaylistRow>[],
    this.pickerPlaylists = const <(String, String, int)>[],
    this.pickerNotice = '',
    this.canCreatePlaylist = false,
    this.savedProviderName = '',
    this.savedUserName = '',
    this.savedOverviewRows = const <PortraitSavedOverviewRow>[],
    this.savedShowArtists = false,
    this.savedScroll = 0,
    this.discover,
    this.savedNotice = '',
    this.mv,
    this.mvPositionMs = 0,
  });

  final BasicViewState state;
  /// 当前平台显示名与「是否内置塞壬」：竖屏/横屏页头、详情页 provider 字段都读它。
  final String providerName;
  final bool isSirenProvider;
  final BasicGlyphPorts ports;
  final ValueChanged<String> onAction;

  /// 点中 HUD 画出来的输入框时回调字段名（`field(name, rect)` 的 name）。
  final ValueChanged<String>? onFieldTap;

  /// 每帧把输入框矩形（舞台单位）交给宿主：登录页的手机号/验证码框要按
  /// 画出来的位置摆输入层，否则输入层按横屏 QML 常量摆，竖屏里根本看不见。
  final ValueChanged<Map<String, Rect>>? onFields;

  /// 列表拖动结束的落点（条目单位，可含小数）；由 basic_app 接到
  /// BasicController.commitLibraryScroll。null = 只支持点选，不支持拖动。
  final ValueChanged<double>? onLibraryScroll;

  /// 拖动中的连续窗口位置（条目单位，可含小数）。Q3 双向跟随契约：
  /// 抬手前必须多次回调（每次指针 move 一次），供宿主把列表窗口实时投影到
  /// 3D 层（BasicApp -> controller.listPosition -> Qt 场景）。只读位置：
  /// 不播放、不换队列、不改选中之外的任何状态；抬手落点仍走 [onLibraryScroll]。
  final ValueChanged<double>? onLibraryScrollUpdate;

  /// 横屏由调用方按逻辑尺寸构造；竖屏用 PortraitStage 注入的 scope。
  final StageGeometry? geometry;
  final HudStage? stage;

  /// 右栏遮罩强度（0..100）：设置页“右侧画面遮罩”的唯一真值来源；
  /// 未接入设置页时为 [HudChrome.defaultArchiveMaskStrength]。
  final double archiveMaskStrength;

  /// 资料库列表页的「列表形式」初始值（Qt `NativeHud::trackListMode`，默认开）。
  /// 只在 surface 内部因 'archive:tab-mode' 翻转；宿主想持久化就传初值并接
  /// [onTrackListModeChanged]，不传则每次重建回到这里给的值。
  final bool trackListMode;

  /// 列表形式翻转后的通知（宿主可存进自己的设置）；null = 只在本 surface 内生效。
  /// 不播放、不改队列、不改选中：Tab Mode 只影响右栏画列表还是画单条面板。
  final ValueChanged<bool>? onTrackListModeChanged;

  /// 原生渲染参数（设置面板的真实值，见 [BasicSceneSettings]）：随快照下发，
  /// 只影响 Qt 渲染，不构成第二份真值。null = 不下发，Qt 用自己的默认。
  final BasicSceneSettings? sceneSettings;

  /// 宿主当前的弹层（'' / 'search' / 'settings' / 'plugins' / 'plugin-detail' / 'queue'）：
  /// 竖屏用它决定画哪一页；横屏只有 'queue' 会额外叠一层播放队列面板。
  final String modal;

  /// 横屏队列面板的首行下标（Qt `queueOffset`，行单位；面板自己 clamp）。
  final int queueOffset;

  /// 竖屏队列页的滚动量（网格单位）；null = 页面按 Qt 规则用当前行置顶。
  final double? queueScroll;

  /// 竖屏队列页的模式 chip 是否展开（Qt `m_queueModesExpanded`）。
  final bool queueModesExpanded;

  /// 插件管理页的数据（[PluginManager.snapshot]）；null = 还没初始化完，页面画空态。
  final PluginSnapshot? plugins;

  /// 竖屏「歌曲操作」面板是否展开（Qt `m_songOptionsExpanded`）。
  final bool songOptionsExpanded;

  /// 「查看评论」入口是否可用（Qt `commentsAvailable`）。
  final bool commentsAvailable;

  /// 「关联 MV」入口是否可用（平台 descriptor 声明 MV 能力）。
  final bool mvAvailable;

  /// 选项面板末尾的「专辑 / 时长」摘要与详情正文。
  final String songOptionsDetail;
  final String songOptionsDetailBody;

  /// 音乐平台页的数据真值（`modal == 'provider'` 时用），见
  /// [BasicHudFrame.build] 的同名参数。
  final List<ProviderDescriptor> providers;
  final String providerId;
  final Map<String, ProviderAccount?> providerAccounts;
  final String providerUserName;
  final bool localMusicEnabled;

  /// 评论页数据（`modal == 'comments'`）；null = 该来源没有评论能力。
  final PortraitCommentsModel? comments;

  /// 评论页滚动位置。
  final double commentsScroll;

  /// 登录页状态（`modal == 'login'`）；null = 尚未装载平台。
  final LoginState? loginState;

  /// 登录方式表。
  final List<ProviderLoginMethod> loginMethods;

  /// 登录页平台名。
  final String loginProviderName;

  /// 平台 `strings.scanHint`。
  final String loginScanHint;

  /// 平台 `strings.deviceNotice`。
  final String loginDeviceNotice;

  /// 冷却文案。
  final String loginCooldownLabel;

  /// 短信重发剩余秒数。
  final int loginSmsRetrySeconds;

  /// 收藏列要画哪一列（1 = 喜欢、2 = 歌单；其它 = 总览退化进喜欢列）。
  final int savedLane;

  /// 收藏列是否停在「我的音乐」总览（Qt `m_savedOverview`）。
  final bool savedOverview;

  /// 喜欢曲目行。
  final List<PortraitLikesRow> likedRows;

  /// 本机歌单行。
  final List<PortraitPlaylistRow> playlistRows;

  /// 「加入歌单」选择器（Qt compact `playlist-picker`）的可选歌单。
  final List<(String, String, int)> pickerPlaylists;

  /// 选择器的状态行（空串 = 不画）。
  final String pickerNotice;

  /// 是否给「＋ 创建歌单」入口（Qt `canCreatePlaylist`）。
  final bool canCreatePlaylist;

  /// 「我的音乐」总览的平台名 / 用户名 / 索引行（Qt `providerName`、`userName`）。
  final String savedProviderName;
  final String savedUserName;
  final List<PortraitSavedOverviewRow> savedOverviewRows;

  /// 是否给「收藏歌手」行（Qt 只在 `discoverTabs` 含 `artists` 时才给）。
  final bool savedShowArtists;

  /// 总览页的滚动偏移（Qt `m_scroll`）。
  final double savedScroll;

  /// 发现页的一帧快照（`modal == 'discover'` 时由宿主算好）。
  final BasicDiscoverSnapshot? discover;

  /// 收藏页状态文案。
  final String savedNotice;

  /// MV 面板数据（`modal == 'mv'`）；null = 没有可展示的 MV 态。
  final MvPanelModel? mv;

  /// MV 面板播放位置（毫秒）。
  final double mvPositionMs;

  /// 插件详情页的 manifest（modal == 'plugin-detail' 时用）。
  final PluginManifest? pluginDetail;
  final bool pluginDetailEnabled;
  final bool pluginDetailUserInstalled;
  final bool pluginDetailCanRollback;
  final String pluginMessage;

  /// 场景层（Qt platform view）的身份键：横竖屏切换时由上层传入**同一个** key，
  /// 让 PlatformView 的 element 被移动（reparent）而不是销毁重建——否则旋转会
  /// 重新创建 QQuickView 并重启场景/Node，播放与相机都会断。
  final Key? sceneKey;

  @override
  State<BasicHudSurface> createState() => _BasicHudSurfaceState();
}

class _BasicHudSurfaceState extends State<BasicHudSurface>
    with SingleTickerProviderStateMixin {
  /// 拖动/惯性中的临时滚动位置（条目单位）；null = 跟随 state.listPosition。
  double? _dragPosition;

  /// 横屏检索面板的行级滚动偏移（舞台像素）。与资料库的 [_dragPosition]
  /// 分开存：检索列表的滚动绝不能改到库表窗口。
  double _searchScroll = 0;

  // ---- 松手惯性（与 Qt/src/SceneDrag.cpp 的 ArchiveDrag / ArchiveMomentum 同构）----
  //
  // 只服务 HUD 自己拥有的列表行拖动：抬手时用最近一段毫秒采样估行速度，够快就按
  // Qt 的一维 archive 物理（摩擦 2.4、收尾 0.6 进入吸行、临界阻尼率 10）继续滑行
  // 再吸到整行；整个过程仍然只走 fractional 的 onLibraryScrollUpdate，落定才用
  // onLibraryScroll 提交一次最近行。
  final List<_ScrollSample> _scrollSamples = <_ScrollSample>[];
  double _scrollVelocity = 0;
  double _scrollTarget = 0;
  bool _scrollCoasting = false;
  bool _scrollAnimating = false;

  /// Qt `m_lastMotion` / `m_motionDirection`：最后一次真实位移的毫秒时间戳与指针
  /// 位移方向。抬手时距最后一次位移 >80ms 视为已停手（速度 0）；反向移动重置采样
  /// 窗口，让释放速度按最后一段方向估计。
  double _scrollLastMotionMs = -1e100;
  double _scrollLastDelta = 0;

  /// 采样口径（Qt `ArchiveDrag::move` / `releaseVelocity`）：最近 120ms 的窗口、
  /// 跨度 <8ms 采不到速度、最多 32 个采样。
  static const double _scrollSampleWindowMs = 120;
  static const double _scrollMotionGapMs = 80;
  static const double _scrollMinSampleSpanMs = 8;
  static const int _scrollSampleLimit = 32;

  /// 物理常量（Qt `ArchiveMomentum::step` 与 `Spring::damp`）：摩擦 2.4、抬手阈值
  /// 0.75、滑行收尾 0.6、吸行阻尼率 10、收尾容差 1e-4 / 5e-3。
  static const double _scrollFriction = 2.4;
  static const double _scrollCoastStart = 0.75;
  static const double _scrollCoastStop = 0.6;
  static const double _scrollSnapRate = 10;
  static const double _scrollPositionEpsilon = 0.0001;
  static const double _scrollVelocityEpsilon = 0.005;

  /// 资料库列表页的列表形式真值（Qt `trackListMode`）：命中 'archive:tab-mode'
  /// 时翻转。只决定右栏画曲目列还是画当前条目的单条面板——选中、滚动窗口、
  /// 播放与队列都不受它影响。
  late bool _trackListMode;

  /// ruler 相邻两项的中心距（lib/hud/widgets/track_ruler.dart 的 88/52 布局，
  /// 相邻为 88）；拖动换算用同一常量，避免手感与绘制不一致。
  static const double _rowStep = 88;

  /// 最近一帧的舞台尺寸（stage 单位）：竖屏拖动的行高换算需要它。
  Size _stageSize = Size.zero;

  /// 共享滚动文字的帧时钟（秒）。只由 [_rollingTicker] 单调推进，不跟触摸绑定：
  /// 初始/暂停/不触摸时标签也会走到可见终态（见 lib/hud/text/rolling_text.dart）。
  double _animationTime = 0;

  /// ticker 的单调累加基准：Ticker.start() 会把 elapsed 归零重来，直接当时间用会
  /// 让字符槽"倒放"，所以只在两次 tick 之间取增量再累加。
  Duration? _tickerBase;
  Ticker? _rollingTicker;
  bool _rollingAnimating = false;

  @override
  void initState() {
    super.initState();
    _trackListMode = widget.trackListMode;
    // 端口里的 RollingLabel 可能比本 State 活得久（端口随 resources 复用），
    // 它们的动画曲线记的是旧时钟；新 State 若从 0 起算，旧曲线会被当成"仍在动"
    // 而空转 ticker。接上端口的当前帧时钟，保证同一时间基准。
    _animationTime = widget.ports.rollingText.time;
    _rollingTicker = createTicker(_onRollingTick);
  }

  @override
  void didUpdateWidget(BasicHudSurface oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 宿主改了初值（例如设置页写回）就跟随；本 State 自己翻转时不回头覆盖宿主，
    // 两边都以「最新一次显式写入」为准。
    if (oldWidget.trackListMode != widget.trackListMode) {
      _trackListMode = widget.trackListMode;
    }
  }

  /// Tab Mode：翻转右栏形式。Qt 侧等价的守卫是 supportsTrackList()（当前条目
  /// 必须是曲目），命中矩形只在满足它时才画出来，这里再判一次防外来回调穿透。
  void _toggleTrackListMode() {
    final List<BasicListItem> items = basicLibraryItems(widget.state);
    if (items.isEmpty) {
      return;
    }
    final int index = basicSelectedItemIndex(widget.state, items);
    if (items[index].kind != 'song') {
      return;
    }
    final bool next = !_trackListMode;
    setState(() => _trackListMode = next);
    widget.onTrackListModeChanged?.call(next);
  }

  @override
  void dispose() {
    // 释放 ticker 并解绑：避免已卸载的 state 继续 setState，也保证外部
    // state.listPosition 不会被残留的 _dragPosition 遮住。
    _rollingTicker?.dispose();
    _rollingTicker = null;
    _dragPosition = null;
    // 惯性也一起收干净：卸载后不能再推进位置、也不能再提交落行。
    _scrollAnimating = false;
    _scrollCoasting = false;
    _scrollVelocity = 0;
    _scrollSamples.clear();
    super.dispose();
  }

  void _onRollingTick(Duration elapsed) {
    final Duration? base = _tickerBase;
    _tickerBase = elapsed;
    if (base == null || !mounted) {
      return;
    }
    final double delta =
        (elapsed - base).inMicroseconds / Duration.microsecondsPerSecond;
    if (delta <= 0) {
      return;
    }
    setState(() => _animationTime += delta);
    // 松手惯性挂在同一个 ticker 上（SingleTickerProvider 只给一个），各自推进：
    // 文字时钟照旧累加，列表动量按同一帧间隔独立积分。
    if (_scrollAnimating) {
      _stepScroll(delta);
    }
  }

  /// 本帧结束后是否继续 ticker。在 build 里不能直接 start/stop，post-frame 生效。
  void _scheduleRollingTicker(bool animating) {
    if (animating == _rollingAnimating &&
        (!animating || (_rollingTicker?.isActive ?? false))) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((Duration _) {
      if (!mounted) {
        return;
      }
      if (animating) {
        if (!(_rollingTicker?.isActive ?? false)) {
          _tickerBase = null;
          _rollingTicker?.start();
        }
      } else {
        _rollingTicker?.stop();
      }
      _rollingAnimating = animating;
    });
  }

  @override
  Widget build(BuildContext context) {
    final StageGeometry geometry = widget.geometry ?? StageGeometryScope.of(context);
    final HudStage stage = widget.stage ?? HudStageScope.of(context);
    final bool portrait = widget.geometry == null;
    final BasicViewState state = widget.state;
    final BasicHudFrame frame = BasicHudFrame.build(
      state: state,
      ports: widget.ports,
      width: stage.width,
      height: stage.height,
      portrait: portrait,
      listPosition: _dragPosition,
      searchScroll: _searchScroll,
      animationTime: _animationTime,
      animateText: true,
      archiveMaskStrength: widget.archiveMaskStrength,
      trackListMode: _trackListMode,
      modal: widget.modal,
      queueOffset: widget.queueOffset,
      queueScroll: widget.queueScroll,
      queueModesExpanded: widget.queueModesExpanded,
      stageScale: geometry.stageScale,
      plugins: widget.plugins,
      pluginDetail: widget.pluginDetail,
      pluginDetailEnabled: widget.pluginDetailEnabled,
      pluginDetailUserInstalled: widget.pluginDetailUserInstalled,
      pluginDetailCanRollback: widget.pluginDetailCanRollback,
      pluginMessage: widget.pluginMessage,
      songOptionsExpanded: widget.songOptionsExpanded,
      commentsAvailable: widget.commentsAvailable,
      mvAvailable: widget.mvAvailable,
      songOptionsDetail: widget.songOptionsDetail,
      songOptionsDetailBody: widget.songOptionsDetailBody,
      providers: widget.providers,
      providerId: widget.providerId,
      providerAccounts: widget.providerAccounts,
      providerUserName: widget.providerUserName,
      localMusicEnabled: widget.localMusicEnabled,
      comments: widget.comments,
      commentsScroll: widget.commentsScroll,
      loginState: widget.loginState,
      loginMethods: widget.loginMethods,
      loginProviderName: widget.loginProviderName,
      loginScanHint: widget.loginScanHint,
      loginDeviceNotice: widget.loginDeviceNotice,
      loginCooldownLabel: widget.loginCooldownLabel,
      loginSmsRetrySeconds: widget.loginSmsRetrySeconds,
      savedLane: widget.savedLane,
      savedOverview: widget.savedOverview,
      likedRows: widget.likedRows,
      playlistRows: widget.playlistRows,
      savedNotice: widget.savedNotice,
      pickerPlaylists: widget.pickerPlaylists,
      pickerNotice: widget.pickerNotice,
      canCreatePlaylist: widget.canCreatePlaylist,
      savedProviderName: widget.savedProviderName,
      savedUserName: widget.savedUserName,
      savedOverviewRows: widget.savedOverviewRows,
      savedShowArtists: widget.savedShowArtists,
      savedScroll: widget.savedScroll,
      discover: widget.discover,
      mv: widget.mv,
      mvPositionMs: widget.mvPositionMs,
    );
    // 输入框矩形回传宿主：登录页手机号/验证码框要按画出来的位置摆输入层。
    widget.onFields?.call(frame.fields);
    // 共享滚动文字有字符槽还在 kReelDuration 内 -> 续帧；静止后停 ticker。
    // 松手惯性期间也必须续帧（同一个 ticker 兼职推进列表动量）。
    _scheduleRollingTicker(frame.animating || _scrollAnimating);
    final HudFrameEnvelope envelope = HudFrameEnvelope.decode(<String, Object?>{
      'generation': frame.generation,
      'frame': <String, Object?>{},
      'commands': frame.commands,
      'hits': <Object?>[for (final HudHit hit in frame.hits) hit.toJson()],
      'state': <String, Object?>{},
    });
    final Rect? sceneRect = basicSceneStageRect(
      portrait: portrait,
      width: stage.width,
      height: stage.height,
    );
    final Widget? scene = sceneRect == null
        ? null
        : _scene(state, geometry, sceneRect, portrait: portrait);
    // 场景矩形已换算到本层坐标（竖屏在 stage 单位里、横屏在逻辑坐标里），
    // 原始指针搬运层要用它把设备坐标归一成 1080 高的舞台坐标。
    final Rect? rawSceneRect =
        sceneRect == null ? null : (portrait ? sceneRect : geometry.rectToLogical(sceneRect));

    _stageSize = Size(stage.width, stage.height);
    final Rect listStageRect = basicLibraryListStageRect(
      portrait: portrait,
      width: stage.width,
      height: stage.height,
      stageScale: geometry.stageScale,
    );
    // 资料库列表页：把列表拖动的手势域从「仅右侧曲目列」扩到「右侧曲目列 ∪ 左侧
    // 3D 直触区」。只在列表阶段扩展——详情/歌词页的 3D 操作
    // （抽唱片、搜索等）保持原样，不受这条规则影响。
    //
    // 3D 直触区就是场景自己的矩形：横屏是整窗（Qt Engine 的 1080 高舞台铺满），
    // 竖屏是上半屏（高的一半，3D 与列表 1:1）。尺寸退化时
    // basicSceneStageRect 返回 null，此时不扩展、不拦截，回到旧行为。
    final Rect? directTouchStageRect = state.phase == BasicPhase.library
        ? basicSceneStageRect(
            portrait: portrait,
            width: stage.width,
            height: stage.height,
          )
        : null;
    final Rect listRect = portrait ? listStageRect : geometry.rectToLogical(listStageRect);
    final Rect? directTouchRect = directTouchStageRect == null
        ? null
        : (portrait ? directTouchStageRect : geometry.rectToLogical(directTouchStageRect));
    // 拖动判据（本层坐标）：曲目列随便起手；3D 直触区要扣掉已有控件与播放条，
    // 不跟按钮/设置/弹层/播放器抢手势。
    final List<Rect> controlStageRects = basicHudHitStageRects(
      frame,
      geometry: geometry,
      android: defaultTargetPlatform == TargetPlatform.android,
    );
    final List<Rect> controlRects = portrait
        ? controlStageRects
        : <Rect>[for (final Rect rect in controlStageRects) geometry.rectToLogical(rect)];
    // 竖屏 compact 版：播放条 + 底栏整块从列表底开始（参考图里它们是一体纸色），
    // 所以排除区从 contentBottom 到底边；横屏仍是右下 96 高的播放条行。
    final Rect playerBarStageRect = portrait
        ? Rect.fromLTWH(
            0,
            listStageRect.bottom,
            stage.width,
            stage.height - listStageRect.bottom,
          )
        : Rect.fromLTWH(
            0,
            stage.height - player.playerBarRowHeight,
            stage.width,
            player.playerBarRowHeight,
          );
    // 横屏检索弹层：面板内的结果列表自己滚（Qt 的 search 列表是独立滚动区，
    // 归 NativeHudSearch 而不是资料库列），所以手势域临时换成那块矩形。
    final bool searchModal = widget.modal == 'search' && !portrait;
    final search_panel.SearchPanelGeometry searchGeometry =
        search_panel.searchPanelGeometry(stage.width);
    final Rect searchListRect = geometry.rectToLogical(
      Rect.fromLTWH(
        searchGeometry.bounds.left + kModalShellHeaderInset,
        searchGeometry.listTop,
        searchGeometry.bounds.width - kModalShellHeaderInset * 2,
        searchGeometry.listBottom - searchGeometry.listTop,
      ),
    );
    final LibraryDragDomain dragDomain = LibraryDragDomain(
      listRect: searchModal ? searchListRect : listRect,
      directTouchRect: searchModal ? null : directTouchRect,
      controlRects: searchModal ? const <Rect>[] : controlRects,
      // 播放条整行排除：它内部有大量间隙，只扣命中矩形会漏出一条「拖动即滚列表」
      // 的窄带。竖屏时播放条在本层底边，与顶部 1080 的直触区不相交。
      excludedRects: searchModal
          ? const <Rect>[]
          : <Rect>[
              portrait ? playerBarStageRect : geometry.rectToLogical(playerBarStageRect),
            ],
    );
    // 命中矩形（stage 单位，已含触控余量）+ 曲目列 + 3D 直触区；竖屏本层就在
    // stage 单位里，横屏本层是逻辑像素，统一在这里换算一次（HitLayer 内部同理
    // 只换一次）。区域集合由 [basicHudRegionRects] 给出：手势层与原生 ownership
    // 判定同源。
    //
    // 直触区只在「扣掉控件后还剩可拖部分」时才并入拦截图：万一将来某个控件把
    // 整块直触区吃掉（hasDirectTouchArea == false），就退回旧行为，不空拦场景。
    final Rect? interceptStageRect =
        dragDomain.hasDirectTouchArea ? directTouchStageRect : null;
    final List<Rect> stageRegions = basicHudRegionRects(
      frame,
      geometry: geometry,
      android: defaultTargetPlatform == TargetPlatform.android,
      portrait: portrait,
      width: stage.width,
      height: stage.height,
      directTouchStageRect: interceptStageRect,
    );
    final List<Rect> regions = portrait
        ? stageRegions
        : <Rect>[for (final Rect rect in stageRegions) geometry.rectToLogical(rect)];
    return Stack(
      children: <Widget>[
        ?scene,
        Positioned.fill(
          child: CustomPaint(
            painter: HudStagePainter(
              envelope: envelope,
              ports: HudPainterPorts(
                text: widget.ports.draw,
                path: widget.ports.pathFor,
                image: widget.ports.imageFor,
              ),
              stage: stage,
            ),
          ),
        ),
        Positioned.fill(
          // 唯一一条指针消费路径：外层 [QtSceneRawPointerLayer] 在 down 时用 HUD
          // 自己的区域图（[basicHudRegionRects]，含列表行、android 触控余量与
          // 资料库列表页的 3D 直触区）定归属，内层 [_HudGestureRegion] 用同一份
          // regions 决定谁参与命中。于是每一条指针序列只有一个消费者：落在 HUD
          // 上＝整串归 HUD（场景不跟着动），落在别处＝整串归 Qt（HUD 不抢），
          // 中途不翻转。
          //
          // 资料库列表页的 3D 直触区归 HUD 之后，Qt 不再收到那里的直达 touch：
          // archive 的翻动由本页 _LibraryDragRecognizer 统一解释（竖直＝列表
          // 窗口，不切换所属列、不播放、不改队列），不再由 Qt 原生 pan 另解释。
          child: rawSceneRect == null
              ? _hudGestureLayer(frame, geometry, portrait, regions, dragDomain)
              : QtSceneRawPointerLayer(
                  sceneRect: rawSceneRect,
                  forwardAt: (Offset local) =>
                      !basicHudOwnsStagePoint(local, regions: regions),
                  child: _hudGestureLayer(frame, geometry, portrait, regions, dragDomain),
                ),
        ),
      ],
    );
  }

  /// HUD 的手势层：点选解析 + 曲目列拖动，只在 [regions] 内参与命中。
  ///
  /// 为什么不再用 `Positioned.fill` + translucent 的 GestureDetector：那会恒返回
  /// true，Qt 的 PlatformView 永远收不到 touch（唱片左右拖不动的机制原因）。
  ///
  /// [dragDomain] 决定「能否从这里起手拖动」：默认判据就是曲目列矩形；资料库
  /// 列表页由 build() 换成「曲目列 ∪ 3D 直触区（扣掉已有控件与播放条）」。拖动
  /// 识别器本身不动——条目单位、fractional update、结束 commit 全部复用。
  Widget _hudGestureLayer(
    BasicHudFrame frame,
    StageGeometry geometry,
    bool portrait,
    List<Rect> regions,
    LibraryDragDomain dragDomain,
  ) {
    return _HudGestureRegion(
      regions: regions,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        // 竖屏手势层在 PortraitStage 的 Transform.scale 里，localPosition 已经是
        // 舞台坐标；而 HitLayer/StageGeometry 的入口约定是窗口逻辑坐标（唯一换算
        // 收在 geometry.toStage 里）。这里先 toLogical 再交给 _dispatch，横屏的
        // Stack 本来就是逻辑坐标，原样传入。92 少这一步，竖屏命中被除了两次 scale。
        onTapUp: (TapUpDetails details) => _dispatch(
          geometry,
          frame,
          portrait ? geometry.toLogical(details.localPosition) : details.localPosition,
          portrait: portrait,
        ),
        child: RawGestureDetector(
          behavior: HitTestBehavior.opaque,
          gestures: <Type, GestureRecognizerFactory>{
            _LibraryDragRecognizer:
                GestureRecognizerFactoryWithHandlers<_LibraryDragRecognizer>(
              () => _LibraryDragRecognizer(debugOwner: this),
              (_LibraryDragRecognizer recognizer) {
                // 起手位置判据（只在 down 时问一次，随后整串手势归本识别器）：
                // 资料库列表页 = 曲目列 ∪ 3D 直触区（扣掉已有控件与播放条）。
                // 其它页面 = dragDomain 只有 listRect，与旧行为一致。
                recognizer.allows = (Offset local) => dragDomain.allows(local);
                recognizer.onStart = (DragStartDetails details) =>
                    _dragStarted(widget.state, details);
                recognizer.onUpdate = (DragUpdateDetails details) =>
                    _dragUpdated(geometry, portrait, details);
                recognizer.onEnd = (DragEndDetails details) =>
                    _dragEnded(details, recognizer.releaseStamp);
                // 被系统打断（onCancel）绝不起惯性：只落回最近一行。
                recognizer.onCancel = () => _dragEnded();
              },
            ),
          },
          child: const SizedBox.expand(),
        ),
      ),
    );
  }

  void _dragStarted(BasicViewState state, DragStartDetails details) {
    if (widget.modal == 'search') {
      // 检索面板：从当前滚动量起手，不碰资料库窗口（[_dragPosition] 只是本次
      // 手势的临时像素位置，抬手即写回 [_searchScroll] 并清空）。
      setState(() {
        _abortScrollMomentum();
        _dragPosition = _searchScroll;
      });
      return;
    }
    // 新手势立即接管：正在跑的滑行/吸行当场停下，并从**当前显示位置**起手（
    // 中途按住不会再跳回 state.listPosition）。
    final double start = _dragPosition ?? _windowOf(state);
    setState(() {
      _abortScrollMomentum();
      _dragPosition = start;
    });
    // Qt ArchiveDrag::start：只留一个起点采样，lastMotion 清空（还没位移）。
    _scrollSamples
      ..clear()
      ..add(_ScrollSample(_scrollMs(details.sourceTimeStamp), start));
    _scrollLastMotionMs = -1e100;
    _scrollLastDelta = 0;
    // 起点也发一次：3D/原生层从当前窗口接上，第一次 move 之前就不会跳。
    widget.onLibraryScrollUpdate?.call(start);
  }

  /// 当前滚动窗口（条目单位）：显式位置优先，其次跟随选中，与 painter 同一规则。
  static double _windowOf(BasicViewState state) {
    final double? explicit = state.listPosition;
    if (explicit != null) {
      return explicit;
    }
    final List<BasicListItem> items = basicLibraryItems(state);
    return items.isEmpty ? 0 : basicSelectedItemIndex(state, items).toDouble();
  }

  void _dragUpdated(
    StageGeometry geometry,
    bool portrait,
    DragUpdateDetails details,
  ) {
    final double? current = _dragPosition;
    if (current == null) {
      return;
    }
    if (widget.modal == 'search') {
      final int rows = BasicHudFrame._portraitSearchRows(widget.state).length;
      final double scale = geometry.stageScale <= 0 ? 1 : geometry.stageScale;
      final double max = search_panel.searchPanelMaxScroll(_stageSize.width, rows);
      // 手指向下 = 内容下移 = 滚动量回退；像素单位（舞台），与绘制同源。
      final double next = current - details.delta.dy / scale;
      setState(() => _dragPosition = next < 0 ? 0 : (next > max ? max : next));
      return;
    }
    final int count = basicLibraryItems(widget.state).length;
    if (count == 0) {
      return;
    }
    // 手指向下 = 内容下移 = 窗口回退到更小的条目号（Qt ruler 的 position 语义）。
    // 竖屏 compact 版行高是 48 网格单位（× unit 换成舞台单位）；横屏仍是 88。
    final double unit = portrait
        ? portraitRowHeight * portraitUnit(_stageSize.width <= 0 ? 1080 : _stageSize.width)
        : _rowStep * geometry.stageScale;
    final double next = current - details.delta.dy / unit;
    final double max = (count - 1).toDouble();
    final double clamped = next < 0 ? 0 : (next > max ? max : next);
    setState(() => _dragPosition = clamped);
    // 抬手速度采样：与 Qt ArchiveDrag::move 同一口径（事件毫秒时间戳、120ms 窗口、
    // 反向只留最后一个采样、最多 32 个）。测试里不给 timeStamp 时全部落在 0ms，
    // 跨度 <8ms 采不到速度 -> 保持「抬手即提交」的旧行为。
    _recordScrollSample(clamped, details.delta, details.sourceTimeStamp);
    // Q3 双向连续跟随：抬手前每个 move 都发一次连续条目位置。宿主把它投影到
    // 3D/原生层，并按 Qt observe 语义当帧进入最近一行（不进播放器、不改队列、
    // 不播报已选中）；落定与播报仍由 _dragEnded 的 onLibraryScroll 提交。
    widget.onLibraryScrollUpdate?.call(clamped);
  }

  /// 抬手（[details] 非空）或被系统打断（[details] 为空）后的收尾。
  ///
  /// 速度快于 [_scrollCoastStart] 才起惯性（滑行 + 吸行，落定提交一次整数行）；
  /// 低速或取消仍走既有语义——立刻提交抬手位置，由宿主四舍五入到最近一行。
  void _dragEnded([DragEndDetails? details, Duration? releaseStamp]) {
    final double? ended = _dragPosition;
    if (ended == null) {
      return;
    }
    if (widget.modal == 'search') {
      // 检索列表只滚不选：不提交选中、不起惯性（Qt 的 search 列表没有吸行语义）。
      setState(() {
        _searchScroll = ended;
        _dragPosition = null;
      });
      _scrollSamples.clear();
      return;
    }
    final int count = basicLibraryItems(widget.state).length;
    final double velocity =
        details == null ? 0 : _scrollVelocityAtRelease(releaseStamp);
    _scrollSamples.clear();
    _scrollLastMotionMs = -1e100;
    _scrollLastDelta = 0;
    if (count == 0 || velocity.abs() < _scrollCoastStart) {
      setState(() => _dragPosition = null);
      // 落点只**选中**：不播放、不换队列（Qt 的 archive 选中无播放副作用）。
      widget.onLibraryScroll?.call(ended);
      return;
    }
    _startScrollMomentum(ended, velocity, count);
  }

  static double _scrollMs(Duration? stamp) =>
      (stamp?.inMicroseconds ?? 0) / 1000;

  /// Qt `ArchiveDrag::move` 的采样部分：毫秒时间戳 + 条目位置。
  void _recordScrollSample(double value, Offset delta, Duration? stamp) {
    final double now = _scrollMs(stamp);
    if (delta.dy != 0) {
      if (_scrollLastDelta * delta.dy < 0 && _scrollSamples.length > 1) {
        // 反向：丢掉旧窗口，只留最后一个采样重新估计释放速度。
        _scrollSamples.removeRange(0, _scrollSamples.length - 1);
      }
      _scrollLastDelta = delta.dy;
      _scrollLastMotionMs = now;
    }
    if (_scrollSamples.isNotEmpty && _scrollSamples.last.time == now) {
      _scrollSamples[_scrollSamples.length - 1] = _ScrollSample(now, value);
    } else {
      _scrollSamples.add(_ScrollSample(now, value));
    }
    _scrollSamples.removeWhere(
      (_ScrollSample sample) => now - sample.time > _scrollSampleWindowMs,
    );
    if (_scrollSamples.length > _scrollSampleLimit) {
      _scrollSamples.removeRange(0, _scrollSamples.length - _scrollSampleLimit);
    }
  }

  /// Qt `ArchiveDrag::releaseVelocity` 的行分量（行/秒）：抬手时已停手 >80ms 或者
  /// 采样跨度 <8ms 都算 0（采不到速度）。
  double _scrollVelocityAtRelease(Duration? stamp) {
    if (_scrollSamples.isEmpty) {
      return 0;
    }
    final double now = _scrollMs(stamp);
    if (now - _scrollLastMotionMs > _scrollMotionGapMs) {
      return 0;
    }
    final _ScrollSample first = _scrollSamples.first;
    final _ScrollSample last = _scrollSamples.last;
    final double span = last.time - first.time;
    if (span < _scrollMinSampleSpanMs) {
      return 0;
    }
    return (last.value - first.value) * (1000 / span);
  }

  /// Qt `ArchiveMomentum` 构造：目标 = floor(position + velocity/friction + 0.5)，
  /// 夹在 [0, count-1]；然后进入滑行（Coasting）阶段。
  void _startScrollMomentum(double position, double velocity, int count) {
    final double max = (count - 1).toDouble();
    double target =
        (position + velocity / _scrollFriction + 0.5).floorToDouble();
    target = target < 0 ? 0 : (target > max ? max : target);
    setState(() {
      _dragPosition = position;
      _scrollVelocity = velocity;
      _scrollTarget = target;
      _scrollCoasting = true;
      _scrollAnimating = true;
    });
  }

  /// 一帧的动量积分（Qt `ArchiveMomentum::step`）：滑行阶段按摩擦 2.4 衰减，速度跌
  /// 到 0.6 以下就用当时的预测位置定目标并转入吸行；吸行阶段用临界阻尼率为 10 的
  /// 弹簧逼近目标，位置与速度都进容差才停稳。全程只发 fractional 位置，停稳才提交。
  void _stepScroll(double dt) {
    final int count = basicLibraryItems(widget.state).length;
    if (count == 0) {
      // 条目被清空/消息窗口退化：直接收尾，不提交一个不存在的行。
      _finishScroll(commit: false);
      return;
    }
    final double max = (count - 1).toDouble();
    double position = _dragPosition ?? _scrollTarget;
    double velocity = _scrollVelocity;
    double target =
        _scrollTarget < 0 ? 0 : (_scrollTarget > max ? max : _scrollTarget);
    bool settled = false;
    if (_scrollCoasting) {
      final double decay = math.exp(-_scrollFriction * dt);
      position += velocity * (1 - decay) / _scrollFriction;
      velocity *= decay;
      if (velocity.abs() < _scrollCoastStop) {
        target = (position + velocity / _scrollFriction + 0.5).floorToDouble();
        target = target < 0 ? 0 : (target > max ? max : target);
        _scrollCoasting = false;
      }
    } else {
      // Qt SceneMotion::Spring::damp(target, 10, seconds) 的闭式解。
      final double delta = position - target;
      final double impulse = velocity + _scrollSnapRate * delta;
      final double decay = math.exp(-_scrollSnapRate * dt);
      position = target + (delta + impulse * dt) * decay;
      velocity = (velocity - _scrollSnapRate * impulse * dt) * decay;
      settled = (position - target).abs() < _scrollPositionEpsilon &&
          velocity.abs() < _scrollVelocityEpsilon;
    }
    position = position < 0 ? 0 : (position > max ? max : position);
    _scrollVelocity = velocity;
    _scrollTarget = target;
    if (settled) {
      _finishScroll();
      return;
    }
    if (position != _dragPosition) {
      setState(() => _dragPosition = position);
      widget.onLibraryScrollUpdate?.call(position);
    }
  }

  /// 停稳：清掉临时位置（重新跟随 state.listPosition）并只提交一次吸附行。
  void _finishScroll({bool commit = true}) {
    final double target = _scrollTarget;
    final bool hadPosition = _dragPosition != null;
    setState(() {
      _dragPosition = null;
      _scrollAnimating = false;
      _scrollCoasting = false;
      _scrollVelocity = 0;
    });
    _scrollSamples.clear();
    if (commit && hadPosition) {
      // 与 _dragEnded 同一条提交语义：只选中、不播放、不换队列。
      widget.onLibraryScroll?.call(target);
    }
  }

  /// 停掉在跑的动量（新手势接管时用）：保留 [_dragPosition] 作为新起手位置。
  void _abortScrollMomentum() {
    _scrollAnimating = false;
    _scrollCoasting = false;
    _scrollVelocity = 0;
  }

  /// Qt 左侧是 3D 容器区；这里挂的是 Qt 自己的场景层（同进程 QQuickView，
  /// platform view），非 Android 平台由 [QtSceneView] 自己给出可见说明。
  ///
  /// 挂载不以网络、选中 id 或歌词页为前提：首页（刚启动的空曲库）同样有场景。
  /// 曲库、播放与相机仍由 Qt 的 Engine 与场景层自己持有；这里只把**同一份**
  /// [BasicViewState] 与 HUD 的动作回调交给场景层（132R 的 QtSceneView 契约），
  /// 不另起第二套状态、也不用 song-key 重建视图。
  Widget _scene(
    BasicViewState state,
    StageGeometry geometry,
    Rect stageRect, {
    required bool portrait,
  }) {
    // 竖屏的 Stack 已在 stage 单位内（PortraitStage 的 Transform.scale）；
    // 横屏的 Stack 是逻辑像素：同一条 stage 矩形只换算一次，绝不双 scale。
    final Rect rect = portrait ? stageRect : geometry.rectToLogical(stageRect);
    return Positioned.fromRect(
      rect: rect,
      child: QtSceneView(
        key: widget.sceneKey,
        state: state,
        settings: widget.sceneSettings,
        onAction: widget.onAction,
      ),
    );
  }

  /// 横屏播放条「歌词 / 点击进入详情」的兜底（见 [BasicHudFrame] 调用点注释）。
  ///
  /// 宿主已支持的动作：`player:lyrics`（打开歌词页）、`player:lyrics-follow`
  /// （回到当前句）、`music:index:%3Ci%3E`（只选中当前行并进详情）。这里不改动作词表、
  /// 不自己开页面，只保证每一次点击都有宿主认得的落点。
  void _dispatchLandscapeLyrics() {
    final BasicViewState state = widget.state;
    if (state.phase == BasicPhase.lyrics) {
      // 已经在歌词页：相位没有再可切的，改发「回到当前句」，点下去看得见滚动。
      widget.onAction('player:lyrics-follow');
      return;
    }
    if (state.song == null) {
      final int row = _playingRowIndex(state);
      if (row >= 0) {
        // `music:index:<i>` 是宿主的"只选中 + 进详情"（basic_app `_selectAt` →
        // `controller.selectLibraryRow`，整条路径同步，返回时 `_song` 已写好），
        // 所以同一帧里随后发 `player:lyrics` 不会再被 `_song == null` 挡掉。
        widget.onAction('music:index:$row');
      }
    }
    widget.onAction('player:lyrics');
  }

  /// 在播曲目在当前可见列表里的行下标（落不到就 -1：远端检索行不在本地 lane 里）。
  int _playingRowIndex(BasicViewState state) {
    final SirenSong? track = state.playingTrack;
    if (track == null) {
      return -1;
    }
    final List<BasicListItem> items = basicLibraryItems(state);
    for (int index = 0; index < items.length; index++) {
      if (items[index].kind == 'song' && items[index].id == track.id) {
        return index;
      }
    }
    return -1;
  }

  void _dispatch(
    StageGeometry geometry,
    BasicHudFrame frame,
    Offset logical, {
    required bool portrait,
  }) {
    final HitLayer layer = HitLayer(
      geometry: geometry,
      android: defaultTargetPlatform == TargetPlatform.android,
    );
    // 输入框优先：HUD 画出来的框和输入层自己的命中面不一定完全重合，点框里
    // 却弹不出键盘时由宿主兜底请求焦点（用户 2026-11-22 报的缺陷）。
    final Offset stagePoint = geometry.toStage(logical);
    // 只有文本输入框才由这条路径抢走命中：`fields` 里还登记着 `playerBounds`
    // （整条播放条的指针归属矩形）之类非文本框，一起吞会让底栏、播放条全部失灵。
    for (final MapEntry<String, Rect> field in frame.fields.entries) {
      if (!_textFieldNames.contains(field.key) || !field.value.contains(stagePoint)) {
        continue;
      }
      widget.onFieldTap?.call(field.key);
      return;
    }
    final HudHit? hit = layer.hitAt(frame.hits, logical);
    if (hit == null) {
      return;
    }
    // Tab Mode 由 surface 自己持有（Qt 里是 NativeHud::trackListMode 的成员，
    // 不是控制器动作）：在这里翻转并消费掉，不再向上转发给 basic_app——
    // 否则宿主没有这个动作的处理器，Tab 键/按钮就是空点。
    if (hit.action == 'archive:tab-mode') {
      _toggleTrackListMode();
      return;
    }
    // 横屏播放条的「歌词」与「点击进入详情」两个热区都发 `player:lyrics`
    // （Qt `PlayerBar.cpp:167-169` 的歌名区命中与 `:201-206` 的词键，
    // Qt 桌面端没有 `player:detail`——那个动作只在竖屏 `ResponsiveHudLayout.cpp:340`），
    // 所以要修的不是动作串，而是宿主 `openLyrics` 的两个**静默前提**：
    //   1. controller 必须有当前曲目（`siren_controller.dart:1948` `_song == null` 直接
    //      返回）。横屏在资料库里把选中行落到专辑/文件夹列时 controller 会清掉 `_song`
    //      （`siren_controller.dart:1916`），纵使还有曲目在播，点歌词也是空点；
    //   2. 相位已经是歌词页时 `openLyrics` 同样什么都不做，再点一次没有任何反馈。
    // 这里补 HUD 侧的兜底，只用宿主已支持的动作：
    //   * `_song` 为空时先把在播曲目落成当前行（`music:index:i` = 只选中 + 进详情，
    //     宿主 `_selectAt` → `controller.selectLibraryRow` 同步写完状态），
    //     紧随其后的 `player:lyrics` 就一定能拿到曲目；
    //   * 已经在歌词页时改发 `player:lyrics-follow`（Qt 歌词面板的「回到当前句」），
    //     让这一下点击有看得见的结果（列表滚回当前句）。
    if (!portrait && hit.action == 'player:lyrics') {
      _dispatchLandscapeLyrics();
      return;
    }
    final bool seek = hit.action.startsWith('player:seek-fraction:');
    final bool volume = hit.action.startsWith('player:volume-fraction:');
    if (seek || volume) {
      final String? action = HitLayer.playerFractionAction(
        control: seek ? 'seek' : 'volume',
        x: stagePoint.dx - hit.x,
        width: hit.width,
      );
      if (action != null) {
        widget.onAction(action);
        return;
      }
    }
    widget.onAction(hit.action);
  }
}

/// HUD 里会登记成文本输入框的 `field` 名字（`PortraitCanvas.field`）。
const Set<String> _textFieldNames = <String>{
  'search',
  'input',
  'account',
  'phone',
  'captcha',
  'code',
  'settingEdit',
  'setting-edit',
};

/// song_detail 的累加器按 Qt op 顺序把每条命令（本身是 List<Object?>）
/// 追加进 List<Object?>，静态类型比 [_HudSink] 的命令表宽一层。
/// 这里按原序逐条还原成命令表：不改顺序、不去重、不丢项；
/// 元素不是命令数组说明上游破坏契约，抛错而不是静默跳过。
List<List<Object?>> _commandRows(List<Object?> commands) {
  final List<List<Object?>> rows = <List<Object?>>[];
  for (var index = 0; index < commands.length; index++) {
    final Object? command = commands[index];
    if (command is List<Object?>) {
      rows.add(command);
    } else {
      throw StateError('song_detail command #$index is not a command array: $command');
    }
  }
  return rows;
}

/// Qt 的封面走 scene-draw 通道（songDetailCoverChannel）；本版没有图片端口，
/// 返回 null 让 song_detail 走自己的缺图分支，不用静态图冒充。
class _NoImages implements detail.SongDetailImagePort {
  const _NoImages();

  @override
  detail.SongDetailImage? image(String key) => null;
}

/// 列表行拖动的一次速度采样（Qt `SceneMotion::ArchiveDrag::Sample`）：毫秒时间戳
/// 与条目单位的滚动位置。只用于抬手速度估计，不参与绘制、命中或选择。
class _ScrollSample {
  const _ScrollSample(this.time, this.value);

  final double time;
  final double value;
}

class _HudSink implements HudSurfaceSink {
  final List<List<Object?>> commands = <List<Object?>>[];
  final List<HudHit> hits = <HudHit>[];

  @override
  void op(List<Object?> command) => commands.add(command);

  @override
  void hit(HudHit hit) => hits.add(hit);

  /// 把页面/播放条产出的命令与命中并入本帧；命中地图走协议解码。
  void addDrawing(List<List<Object?>> drawn, List<Map<String, Object?>> rawHits) {
    commands.addAll(drawn);
    hits.addAll(decodeHudHits(rawHits).hits);
  }

  /// 竖屏重排：同一套 1080 设计的命令整体下移，命中同步平移，
  /// 绘制与命中仍是同一份坐标（不各自推导）。
  void shifted(double dx, double dy, void Function(_HudSink sink) draw) {
    final _HudSink inner = _HudSink();
    draw(inner);
    if (inner.commands.isEmpty) {
      return;
    }
    op(<Object?>['save']);
    if (dx != 0 || dy != 0) {
      op(<Object?>['translate', dx, dy]);
    }
    commands.addAll(inner.commands);
    op(<Object?>['restore']);
    for (final HudHit hit in inner.hits) {
      hits.add(HudHit(
        x: hit.x + dx,
        y: hit.y + dy,
        width: hit.width,
        height: hit.height,
        action: hit.action,
        label: hit.label,
        fixed: hit.fixed,
      ));
    }
  }
}

/// `queue_modal.QueueModalGlyphs` 适配：队列卡片只量宽度（Qt Canvas::fit）。
class _CommentPanelGlyphs implements comments_modal.CommentPanelGlyphs {
  const _CommentPanelGlyphs(this.ports);

  final BasicGlyphPorts ports;

  @override
  double width(String value, double size, String weight) => ports.width(value, size, weight);

  @override
  List<String> wrap(String value, double limit, double size, String weight) =>
      ports.wrap(value, limit, size, weight);
}

class _QueueModalGlyphs implements queue_modal.QueueModalGlyphs {
  const _QueueModalGlyphs(this.ports);

  final BasicGlyphPorts ports;

  @override
  double width(String value, double size, String weight) =>
      ports.width(value, size, weight);
}
