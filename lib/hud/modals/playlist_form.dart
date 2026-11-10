// lib/hud/modals/playlist_form.dart
//
// T36 / PAGE-LIBRARY —— 个人库「创建/重命名歌单」写操作浮层（playlist-form）。
// 计划映射：docs/superpowers/plans/2026-11-09-qt-to-flutter-parity-plan.md:630-633（T36 第 1 条
// 「创建歌单」写操作 + 表格写路径）。
// 本文件属于 public-only 提交 "feat(hud): port Qt library and playlist modals"；
// login panel / login QR 不在本提交，也不被本文件 import。
//
// 基线 8ed3067b0812eb2612f7841ec127a6e8ca93231b 上的 Qt 源证据（逐字，只读引用）：
//   Qt/qml/Overlay.qml:355-484        共用编辑浮层 formFields（字段/最大长度/键盘/返回/Escape/提交）
//   Qt/src/NativeHudModal.cpp:26-51   modalTitle("playlist-form") = "PLAYLIST EDITOR"
//   Qt/src/NativeHudModal.cpp:52-75   modalSubtitle("playlist-form") = "编辑我的歌单"
//   Qt/src/NativeHudModal.cpp:198-202 弹层头/返回按钮/标题/副标题几何
//   Qt/src/NativeHudModal.cpp:240-243 playlist-form 面板：标签/提示/状态行
//   Qt/src/NativeHud.cpp:140-159      modalBounds：min(1260, width-100)、left 居中、y=122、高 836
//   Qt/src/NativeHud.cpp:175-221      state()：inputX/inputWidth/modalOffset/modalOpacity/formKind/formPID
//   Qt/src/NativeHud.cpp:48-79        fit()/limited()：状态行按宽度截断并追加省略号
//   Qt/src/NativeHud.cpp:102-108      hit()：hits 六字段原序 x/y/width/height/action/label
//   Qt/src/NativeHudLibrary.cpp:60-72 libraryToolbarActionWidth()：modal != "saved" 时为 0
//   Qt/src/NativeHudLibrary.cpp:95-117 创建/刷新按钮几何与 action 串
//   Qt/src/NativeHudLibrary.cpp:6-18  LibraryInset=53 / LibraryBarTop=172 / LibraryBarHeight=66
//   Qt/src/NativeHudMusic.cpp:314-317 "music:create-playlist" 入口（formKind=create，formPID 清空）
//   Qt/src/NativeHudMusic.cpp:346-351 "music:rename-playlist" 入口（canEditPlaylist 门）
//   Qt/src/NativeHudController.cpp:64-69  isLocal() 时 playlist-form 不可打开
//   Qt/src/NativeHudController.cpp:165-180 form()：playlist-form + fields["name"] → playlistForm()
//   Qt/src/NativeHudController.cpp:913-922 全局 Escape → "close-modal"
//   Qt/src/Engine.cpp:867-876          submitForm()：非 login 时 values = {"name": account}
//   Qt/src/MusicMutation.cpp:410-420   校验：trimmed、maximum=qq?20:100、空/超长 → 状态文案
//   Qt/src/MusicMutation.cpp:421-455   siren 本地歌单 create/rename 与状态文案
//   Qt/src/MusicMutation.cpp:457-465   重命名所有权门「只能编辑自己创建的歌单」
//   Qt/src/MusicMutation.cpp:466-493   写路由 /playlist/create 与 /playlist/name/update + 表格写回语义
//   Qt/src/MusicMutation.cpp:186-200   远端 mutate 串行化门（!canMutate || writeLoading || uid.isEmpty()）；
//                                      只在 :421-455 siren 分支与 :457-465 rename 所有权门之后执行，
//                                      不是 playlist-form 的通用入口门。
//
// 本文件自包含 + 可注入：只依赖 flutter/material、flutter/services、dart:math；不 import 任何
// 本树尚不存在的跨模块（lib/hud/protocol/**、hits/input 层、library_modal）。表格刷新只暴露
// 端口契约（SavedPlaylistTablePort），不在本文件实现表格，也不提供任何假数据兜底。
//
// 竖屏：横屏几何逐值取自 Qt 源；竖屏是新增响应式全语义，源码无竖屏像素证据，相关段落已逐处标注。
//
// 弹层框架分两段 owner，均不属于本层（plan:180：3D → HUD → modal 遮罩 → hits → chrome）：
//   - 遮挡层（modal 遮罩槽，必须在内容之前）：全屏遮罩 + 弹层不透明底
//     （Qt/src/NativeHudModal.cpp:163-165、:171-172）；
//   - chrome 层（hits 之后）：RHINE LAB 行 / 标题 / 副标题 / "← 返回"
//     （Qt/src/NativeHudModal.cpp:198-202）与唯一 close-modal hit，owner 是
//     计划中的 lib/hud/pages/chrome.dart（PAGE-ARCHIVE）。
// 本层只画 playlist-form 的表单内容（标签/字段/提示/状态/提交），不画底、不画前景框架，
// 也不发第二个 close-modal 命中；字段的 Escape 仍按 Overlay.qml:406 发 close-modal 动作。

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// 逐字取自 Qt 源的常量（含行号注释，禁止改写成同义串）。
abstract final class PlaylistFormSpec {
  /// 弹层 kind：Overlay.qml:357 / NativeHudController.cpp:67。
  static const String modalKind = 'playlist-form';

  /// 表单模式串：NativeHudMusic.cpp:315（formKind="create"）/ :348（"rename"）。
  static const String formKindCreate = 'create';
  static const String formKindRename = 'rename';

  /// 关闭动作：Overlay.qml:406/460、NativeHudModal.cpp:200、NativeHudController.cpp:686。
  static const String actionCloseModal = 'close-modal';

  /// 入口动作串（逐字）：NativeHudLibrary.cpp:110 / NativeHudDetail.cpp:413 / NativeHudLibrary.cpp:116。
  static const String actionCreatePlaylist = 'music:create-playlist';
  static const String actionRenamePlaylist = 'music:rename-playlist';
  static const String actionRefreshPersonal = 'music:refresh-personal';

  /// 文案（逐字）
  static const String backLabel = '← 返回'; // NativeHudModal.cpp:199
  static const String submitLabel = '保存 →'; // Overlay.qml:472
  static const String loginSubmitLabel = '登录 →'; // Overlay.qml:472
  static const String fieldAccessibleName = '歌单名称'; // Overlay.qml:398
  static const String submitAccessibleName = '提交表单'; // Overlay.qml:477
  static const String labelCreate = '歌单名称'; // NativeHudModal.cpp:241
  static const String labelRename = '新歌单名称'; // NativeHudModal.cpp:241
  static const String hintPlain = '按 ENTER 提交'; // NativeHudModal.cpp:242
  static const String hintQq = '1–20 字 / 按 ENTER 提交'; // NativeHudModal.cpp:242
  // 以下三项与 layout.backButton 是 chrome 层的几何/文案契约；本层不绘制，
  // 由 lib/hud/pages/chrome.dart（PAGE-ARCHIVE）统一 owner。
  static const String panelTitle = 'PLAYLIST EDITOR'; // NativeHudModal.cpp:35
  static const String panelSubtitle = '编辑我的歌单'; // NativeHudModal.cpp:60
  static const String panelHeader = 'RHINE LAB / MUSIC DATABASE / MUSIC DIRECTORY'; // NativeHudModal.cpp:198
  static const String createButtonLabel = '创建歌单'; // NativeHudLibrary.cpp:110
  static const String refreshButtonLabel = '刷新个人库'; // NativeHudLibrary.cpp:116

  /// 字段最大长度（UTF-16 码元，对齐 Qt maximumLength）：Overlay.qml:395。
  static const int fieldMaxLength = 100;
  /// 登录手机号字段最大长度（同组件 login 分支，供 login_panel 复用同一常量）。
  static const int loginPhoneMaxLength = 11;
  /// 名称上限（Unicode 码点，对齐 MusicMutation.cpp:412 的 toUcs4().size()）。
  static const int nameMaximumQq = 20;
  static const int nameMaximumDefault = 100;

  /// 校验文案：MusicMutation.cpp:414「请输入 1–」+ maximum + 「 字歌单名称」（U+2013 连字号）。
  static String nameInvalidMessage(int maximum) =>
      '请输入 1–' + maximum.toString() + ' 字歌单名称';

  static const String statusRenameNotOwned = '只能编辑自己创建的歌单'; // MusicMutation.cpp:459
  static const String statusSirenCreatedPrefix = '已创建歌单：'; // MusicMutation.cpp:434
  static const String statusSirenCreateFailed = '无法创建歌单，请检查名称或数量上限'; // MusicMutation.cpp:436
  static const String statusSirenRenamed = '已重命名歌单'; // MusicMutation.cpp:446
  static const String statusSirenRenameFailed = '无法重命名歌单'; // MusicMutation.cpp:448
  static const String statusEditUnsupportedSuffix = '当前支持读取与播放'; // MusicMutation.cpp:190
  static const String statusLoginRequiredPrefix = '请先登录'; // MusicMutation.cpp:192
  static const String statusQqFeatureClosed = '当前 QQ 服务未开放此编辑功能'; // MusicMutation.cpp:194

  /// 颜色（Overlay.qml:382/392/415/468/473）
  static const Color fieldFillDark = Color(0xFF30312B); // #30312b
  static const Color fieldFillLight = Color(0xFFD9D8CE); // #d9d8ce
  static const Color fieldTextDark = Color(0xFFEEEEEB); // #eeeeeb
  static const Color fieldTextLight = Color(0xFF161914); // #161914
  static const Color submitFill = Color(0xFF777B60); // #777b60
  static const Color submitText = Color(0xFFF0EEE5); // #f0eee5

  /// HUD 文本 ink()：dark {0.92,0.92,0.92,1,"calibratedWhite"}、
  /// light {0.08,0.085,0.075,1,"calibratedRGB"}（NativeHud.cpp:10-15）。
  /// 仅用于 HUD 绘制文本；输入框文本仍用 Overlay.qml 的 fieldText*。
  static const Color hudInkDark = Color(0xFFEBEBEB);
  static const Color hudInkLight = Color(0xFF141613);

  /// 字号（stage 单位，乘 stageScale）：Overlay.qml:393/421/474、NativeHudModal.cpp:198-202/241-243。
  static const double fieldFontSize = 19;
  static const double submitFontSize = 14;
  static const double backFontSize = 20;
  static const double headerFontSize = 11;
  static const double titleFontSize = 38;
  static const double subtitleFontSize = 15;
  static const double labelFontSize = 15;
  static const double hintFontSize = 12;
  static const double statusFontSize = 12;

  /// 横屏 stage 几何（NativeHud.cpp:140-159、Overlay.qml:358-360、NativeHudModal.cpp:198-243）。
  static const double stageHeight = 1080; // Overlay.qml:22
  static const double panelTop = 122; // NativeHud.cpp:158
  static const double panelHeight = 836; // NativeHud.cpp:158
  static const double panelMaxWidth = 1260; // NativeHud.cpp:153
  static const double panelWidthInset = 100; // NativeHud.cpp:153
  static const double inset = 53; // LibraryInset，NativeHudLibrary.cpp:7
  static const double inputWidthInset = 106; // NativeHud.cpp:186
  static const double fieldTop = 430; // Overlay.qml:379/388
  static const double fieldHeight = 55; // Overlay.qml:381/390
  static const double fieldTextInsetX = 14; // Overlay.qml:387
  static const double fieldTextInsetRight = 28; // Overlay.qml:389（非 login 分支）
  static const double submitTop = 530; // Overlay.qml:464（非 login 分支）
  static const double submitWidth = 170; // Overlay.qml:466
  static const double submitHeight = 36; // Overlay.qml:467
  static const double labelTopOffset = 240; // NativeHudModal.cpp:241（面板内偏移）
  static const double hintTopOffset = 420; // NativeHudModal.cpp:242
  static const double statusTopOffset = 775; // NativeHudModal.cpp:243
  static const double backTopOffset = 18; // NativeHudModal.cpp:199
  static const double backWidth = 167; // NativeHudModal.cpp:199
  static const double backHeight = 54; // NativeHudModal.cpp:199
  static const double backRightInset = 220; // NativeHudModal.cpp:199
  static const double headerTopOffset = 37; // NativeHudModal.cpp:198
  static const double titleTopOffset = 91; // NativeHudModal.cpp:201
  static const double subtitleTopOffset = 147; // NativeHudModal.cpp:202

  /// 个人库工具栏（同一写操作的入口几何，界面实现在 library_modal；此处只给逐值契约）。
  /// NativeHudLibrary.cpp:107-117、:6-18。
  static const double libraryBarTop = 172;
  static const double libraryBarHeight = 66;
  static const double libraryCreateWidth = 150;
  static const double libraryRefreshWidth = 110;
  static const double libraryActionGap = 10;
}

/// playlist-form 的模式（wire 串与 HUD state 的 formKind 完全一致）。
enum PlaylistFormKind {
  create(PlaylistFormSpec.formKindCreate),
  rename(PlaylistFormSpec.formKindRename);

  const PlaylistFormKind(this.wire);

  /// 与 NativeHud.cpp:199 的 state["formKind"] 同值。
  final String wire;

  static PlaylistFormKind? fromWire(String value) {
    for (final PlaylistFormKind kind in PlaylistFormKind.values) {
      if (kind.wire == value) {
        return kind;
      }
    }
    return null;
  }
}

/// 注入快照：本浮层读到的全部 HUD 状态，字段名对应 NativeHud::state()（NativeHud.cpp:175-221）。
@immutable
class PlaylistFormView {
  const PlaylistFormView({
    required this.formKind,
    required this.provider,
    this.providerName = '',
    this.status = '',
    this.uid = '',
    this.loginBusy = false,
    this.writeLoading = false,
    this.editable = true,
    this.modalOffset = 0,
    this.modalOpacity = 1,
    this.stageWidth = 1920,
    this.stageScale = 1,
    this.dark = false,
    this.performanceIdle = false,
    this.generation = 0,
    this.formPid = '',
    this.visible = true,
    this.portrait = false,
    this.viewport = Size.zero,
  });

  /// "create" | "rename"（NativeHud.cpp:199 formKind）。
  final PlaylistFormKind formKind;

  /// 当前平台 id：netease / qq / kugou / local / siren（MusicLibrary provider）。
  final String provider;

  /// providerName() 结果，用于状态文案拼接（MusicMutation.cpp:190/192）。
  final String providerName;

  /// music.status：面板状态行原文（NativeHudModal.cpp:243）。
  final String status;

  /// uid：为空时写操作被门拦下（MusicMutation.cpp:188）。
  final String uid;

  /// accountLoading（NativeHud.cpp:196 loginBusy）；playlist-form 不使用，保留以对齐 QML 表达式。
  final bool loginBusy;

  /// MusicLibrary::writeLoading（MusicLibrary.h:186、MusicMutation.cpp:188/202/234）。
  final bool writeLoading;

  /// MusicLibrary::editable()（MusicLibrary.h:95-97）。
  final bool editable;

  /// motion.offset（NativeHud.cpp:205）→ Overlay.qml:359 的 y 位移。
  final double modalOffset;

  /// motion.opacity（NativeHud.cpp:204）→ Overlay.qml:362 的 opacity。
  final double modalOpacity;

  /// HUD 舞台宽（NativeHud::width），用于 modalBounds（NativeHud.cpp:140）。
  final double stageWidth;

  /// stageScale = 窗口高 / 1080（Overlay.qml:22）。
  final double stageScale;

  final bool dark;

  /// performance.idle：cursorVisible = activeFocus && !idle（Overlay.qml:394）。
  final bool performanceIdle;

  /// m_searchGeneration 代次；提交回调只在代次未变时生效（NativeHudController.cpp:173-177）。
  final int generation;

  /// formPID：rename 目标歌单 id（NativeHudMusic.cpp:349）。
  final String formPid;

  /// Overlay.qml:357 的 visible。
  final bool visible;

  /// 竖屏：无 Qt 竖屏像素证据，见 PlaylistFormLayout.portrait。
  final bool portrait;

  /// 竖屏布局用的视口尺寸（逻辑像素）。
  final Size viewport;

  /// NativeHudController.cpp:64-69：isLocal() 时 playlist-form 直接拒绝打开。
  bool get openable => provider != 'local';

  /// Overlay.qml:396 / :414 / :465 的表达式「modal !== "login" || !loginBusy」；
  /// playlist-form 分支恒为 true。本文件不自创禁用规则：提交中 busy 语义由端口侧的
  /// writeLoading 串行化门（MusicMutation.cpp:188）表达，而不是把控件置灰。
  bool get fieldEnabled => true;
  bool get submitEnabled => true;

  /// Overlay.qml:395：maximumLength: modal === "login" ? 11 : 100。
  int get fieldMaximumLength => PlaylistFormSpec.fieldMaxLength;

  /// NativeHudModal.cpp:241。
  String get nameLabel =>
      formKind == PlaylistFormKind.create ? PlaylistFormSpec.labelCreate : PlaylistFormSpec.labelRename;

  /// NativeHudModal.cpp:242。
  String get nameHint => provider == 'qq' ? PlaylistFormSpec.hintQq : PlaylistFormSpec.hintPlain;

  /// MusicMutation.cpp:412：maximum = provider == "qq" ? 20 : 100。
  int get nameMaximum =>
      provider == 'qq' ? PlaylistFormSpec.nameMaximumQq : PlaylistFormSpec.nameMaximumDefault;
}

/// HUD 文本槽：text(value, x, y, size, weight)（NativeHud.cpp:40-43）的 Flutter 侧等价。
@immutable
class HudTextSlot {
  const HudTextSlot(this.at, this.size, {this.demibold = false});

  /// stage 坐标下的 (x, y)。
  final Offset at;
  final double size;

  /// HUD weight "demibold"（NativeHudModal.cpp:199/201）→ FontWeight.w600。
  final bool demibold;

  FontWeight get weight => demibold ? FontWeight.w600 : FontWeight.w400;
}

/// playlist-form 的一条 HUD 命中（六字段原序 x/y/width/height/action/label，NativeHud.cpp:102-108）。
@immutable
class PlaylistFormHit {
  const PlaylistFormHit({
    required this.x,
    required this.y,
    required this.width,
    required this.height,
    required this.action,
    required this.label,
  });

  final double x;
  final double y;
  final double width;
  final double height;
  final String action;
  final String label;

  Rect get rect => Rect.fromLTWH(x, y, width, height);

  Rect scaled(double scale) => Rect.fromLTWH(x * scale, y * scale, width * scale, height * scale);
}

/// 横屏 stage 几何 + 竖屏响应式几何。
///
/// 横屏全部数值来自 Qt 源；缩放由调用方用 [scale] 施加（Overlay 用 stageScale = 高/1080）。
@immutable
class PlaylistFormLayout {
  const PlaylistFormLayout({
    required this.scale,
    required this.portrait,
    required this.panel,
    required this.header,
    required this.backButton,
    required this.title,
    required this.subtitle,
    required this.fieldLabel,
    required this.fieldBox,
    required this.fieldRect,
    required this.hint,
    required this.status,
    required this.submitButton,
  });

  /// 横屏：NativeHud.cpp:140-159 + Overlay.qml:358-360/379-390/462-467。
  factory PlaylistFormLayout.stage({required double stageWidth, required double scale}) {
    final double panelWidth =
        math.min(PlaylistFormSpec.panelMaxWidth, stageWidth - PlaylistFormSpec.panelWidthInset);
    final double left = (stageWidth - panelWidth) / 2;
    // NativeHudLibrary.cpp:60-72：modal != "saved" 时 libraryToolbarActionWidth() == 0。
    const double toolbarActionWidth = 0;
    final double inputWidth = panelWidth - PlaylistFormSpec.inputWidthInset - toolbarActionWidth;
    final double fieldLeft = left + PlaylistFormSpec.inset;
    return PlaylistFormLayout(
      scale: scale,
      portrait: false,
      panel: Rect.fromLTWH(left, PlaylistFormSpec.panelTop, panelWidth, PlaylistFormSpec.panelHeight),
      header: HudTextSlot(
        Offset(fieldLeft, PlaylistFormSpec.panelTop + PlaylistFormSpec.headerTopOffset),
        PlaylistFormSpec.headerFontSize,
      ),
      backButton: Rect.fromLTWH(
        left + panelWidth - PlaylistFormSpec.backRightInset,
        PlaylistFormSpec.panelTop + PlaylistFormSpec.backTopOffset,
        PlaylistFormSpec.backWidth,
        PlaylistFormSpec.backHeight,
      ),
      title: HudTextSlot(
        Offset(fieldLeft, PlaylistFormSpec.panelTop + PlaylistFormSpec.titleTopOffset),
        PlaylistFormSpec.titleFontSize,
        demibold: true,
      ),
      subtitle: HudTextSlot(
        Offset(fieldLeft, PlaylistFormSpec.panelTop + PlaylistFormSpec.subtitleTopOffset),
        PlaylistFormSpec.subtitleFontSize,
      ),
      fieldLabel: HudTextSlot(
        Offset(fieldLeft, PlaylistFormSpec.panelTop + PlaylistFormSpec.labelTopOffset),
        PlaylistFormSpec.labelFontSize,
      ),
      fieldBox: Rect.fromLTWH(
        fieldLeft,
        PlaylistFormSpec.fieldTop,
        inputWidth,
        PlaylistFormSpec.fieldHeight,
      ),
      fieldRect: Rect.fromLTWH(
        fieldLeft + PlaylistFormSpec.fieldTextInsetX,
        PlaylistFormSpec.fieldTop,
        inputWidth - PlaylistFormSpec.fieldTextInsetRight,
        PlaylistFormSpec.fieldHeight,
      ),
      hint: HudTextSlot(
        Offset(fieldLeft, PlaylistFormSpec.panelTop + PlaylistFormSpec.hintTopOffset),
        PlaylistFormSpec.hintFontSize,
      ),
      status: HudTextSlot(
        Offset(fieldLeft, PlaylistFormSpec.panelTop + PlaylistFormSpec.statusTopOffset),
        PlaylistFormSpec.statusFontSize,
      ),
      submitButton: Rect.fromLTWH(
        fieldLeft + inputWidth - PlaylistFormSpec.submitWidth,
        PlaylistFormSpec.submitTop,
        PlaylistFormSpec.submitWidth,
        PlaylistFormSpec.submitHeight,
      ),
    );
  }

  /// 竖屏响应式新增几何。
  ///
  /// 无 Qt 竖屏像素证据：Qt 只在横屏 1080 舞台归一化（Overlay.qml:22），不存在竖屏帧。
  /// 这里仅新增响应式排布（全宽字段、全宽提交、纵向延伸），语义/命中/action 串与横屏完全一致；
  /// 不得据此倒推为 Qt 像素，也不得被当作取证画面。scale 恒为 1（竖屏用逻辑像素直排）。
  factory PlaylistFormLayout.portrait({required Size viewport}) {
    const double margin = 16;
    const double contentInset = 16;
    final double width = viewport.width - margin * 2;
    final double contentWidth = width - contentInset * 2;
    final double left = margin + contentInset;
    const double headerTop = 24;
    const double backTop = 24;
    const double titleTop = 96;
    const double subtitleTop = 150;
    const double fieldLabelTop = 232;
    const double fieldTop = 264;
    const double fieldHeight = 64;
    final double submitTop = fieldTop + fieldHeight + 24;
    const double submitHeight = 64;
    final double hintTop = submitTop + submitHeight + 16;
    final double statusTop = hintTop + 28;
    return PlaylistFormLayout(
      scale: 1,
      portrait: true,
      panel: Rect.fromLTWH(margin, 0, width, viewport.height),
      header: HudTextSlot(Offset(left, headerTop), PlaylistFormSpec.headerFontSize),
      backButton: Rect.fromLTWH(
        margin + width - PlaylistFormSpec.backWidth,
        backTop,
        PlaylistFormSpec.backWidth,
        PlaylistFormSpec.backHeight,
      ),
      title: HudTextSlot(Offset(left, titleTop), PlaylistFormSpec.titleFontSize, demibold: true),
      subtitle: HudTextSlot(Offset(left, subtitleTop), PlaylistFormSpec.subtitleFontSize),
      fieldLabel: HudTextSlot(Offset(left, fieldLabelTop), PlaylistFormSpec.labelFontSize),
      fieldBox: Rect.fromLTWH(left, fieldTop, contentWidth, fieldHeight),
      fieldRect: Rect.fromLTWH(left + 12, fieldTop, contentWidth - 24, fieldHeight),
      hint: HudTextSlot(Offset(left, hintTop), PlaylistFormSpec.hintFontSize),
      status: HudTextSlot(Offset(left, statusTop), PlaylistFormSpec.statusFontSize),
      submitButton: Rect.fromLTWH(left, submitTop, contentWidth, submitHeight),
    );
  }

  final double scale;
  final bool portrait;
  final Rect panel;
  final HudTextSlot header;
  final Rect backButton;
  final HudTextSlot title;
  final HudTextSlot subtitle;
  final HudTextSlot fieldLabel;
  final Rect fieldBox;
  final Rect fieldRect;
  final HudTextSlot hint;
  final HudTextSlot status;
  final Rect submitButton;

  Rect scaled(Rect rect) =>
      Rect.fromLTWH(rect.left * scale, rect.top * scale, rect.width * scale, rect.height * scale);

  /// 状态行可用宽度：limited(music.status, x+53, y+775, 12, usable-106)（NativeHudModal.cpp:243）。
  double get statusMaxWidth => panel.width - PlaylistFormSpec.inputWidthInset;

  /// 本层不产生 HUD 命中：Qt 在 NativeHudModal.cpp:173 清空 hits 后登记的唯一条目是
  /// 返回按钮（:199-200），而该按钮属于 chrome 层（见文件头注释）。字段与提交是 QML 控件
  /// （Overlay.qml:384-483），本来也不产生 HUD action 串。保留空实现是为了让集成方明确
  /// "此处无命中"，而不是忘记挂 hit。
  List<PlaylistFormHit> nativeHits() => const <PlaylistFormHit>[];
}

/// 名称校验结果。
@immutable
class PlaylistFormValidation {
  const PlaylistFormValidation({
    required this.accepted,
    required this.trimmedName,
    this.message = '',
  });

  final bool accepted;

  /// Qt 先做 trimmed()（MusicMutation.cpp:411），下游用这个名字。
  final String trimmedName;

  /// 非空即 MusicMutation.cpp:414 的原文。
  final String message;
}

/// 名称校验：MusicMutation.cpp:410-420 的逐值镜像。
abstract final class PlaylistFormValidator {
  /// maximum = provider == "qq" ? 20 : 100（MusicMutation.cpp:412）。
  static int maximumFor(String provider) =>
      provider == 'qq' ? PlaylistFormSpec.nameMaximumQq : PlaylistFormSpec.nameMaximumDefault;

  /// name = name.trimmed(); if (name.isEmpty() || name.toUcs4().size() > maximum)。
  ///
  /// Qt 用 toUcs4().size()（Unicode 码点）；Dart 等价是 String.runes.length。
  /// 这与字段截断口径（UTF-16 码元，Overlay.qml:395 maximumLength）在源里本就不同，
  /// 本文件保持 1:1，不把两者统一。
  static PlaylistFormValidation validateName({required String rawName, required String provider}) {
    final String trimmed = rawName.trim();
    final int maximum = maximumFor(provider);
    if (trimmed.isEmpty || trimmed.runes.length > maximum) {
      return PlaylistFormValidation(
        accepted: false,
        trimmedName: trimmed,
        message: PlaylistFormSpec.nameInvalidMessage(maximum),
      );
    }
    return PlaylistFormValidation(accepted: true, trimmedName: trimmed);
  }
}

/// 字段截断：对齐 Qt TextInput.maximumLength（Overlay.qml:395）的 UTF-16 码元口径。
///
/// Flutter 内置 maxLength/LengthLimitingTextInputFormatter 按字素簇（characters）计数并显示计数器，
/// 与 Qt 的 QString 长度（UTF-16 码元、无计数器）不是同一口径，因此这里自实现。
class PlaylistFormTextInputFormatter extends TextInputFormatter {
  const PlaylistFormTextInputFormatter(this.maxLength);

  final int maxLength;

  @override
  TextEditingValue formatEditUpdate(TextEditingValue oldValue, TextEditingValue newValue) {
    if (newValue.text.length <= maxLength) {
      return newValue;
    }
    final String clamped = newValue.text.substring(0, maxLength);
    int clampOffset(int value) => math.min(math.max(value, 0), maxLength);
    final TextRange composing = newValue.composing;
    final bool composingKept = composing.isValid && composing.end <= maxLength;
    return TextEditingValue(
      text: clamped,
      selection: TextSelection(
        baseOffset: clampOffset(newValue.selection.baseOffset),
        extentOffset: clampOffset(newValue.selection.extentOffset),
      ),
      composing: composingKept ? composing : TextRange.empty,
    );
  }
}

/// 写回表格的一行（字段取自 MusicMutation.cpp:470-491 用到的 playlist 对象键）。
@immutable
class PlaylistFormRow {
  const PlaylistFormRow({
    required this.id,
    required this.title,
    this.creatorId = '',
    this.kind = 'playlist',
    this.provider = '',
    this.special = false,
  });

  final String id;
  final String title;
  final String creatorId;
  final String kind;
  final String provider;

  /// 「我喜欢的音乐」等特殊歌单：canEditPlaylist 直接拒绝（MusicMutation.cpp:53-55）。
  final bool special;
}

/// 写操作结果。
///
/// 失败时 [status] 必须是模型原文（MusicMutation.cpp:414/436/448/459 等），由浮层原样回显。
/// rename 成功时 [verifiedTitle] 是服务端确认名（MusicMutation.cpp:479 body["name"] 优先）。
@immutable
class PlaylistFormResult {
  const PlaylistFormResult.accepted({this.row, this.verifiedTitle = ''})
      : ok = true,
        status = '';

  const PlaylistFormResult.rejected({required this.status})
      : ok = false,
        row = null,
        verifiedTitle = '';

  final bool ok;
  final String status;
  final PlaylistFormRow? row;
  final String verifiedTitle;
}

/// 提交端口：create → /playlist/create；rename → /playlist/name/update（MusicMutation.cpp:466-468）。
///
/// 端口实现（集成后由 library_modal / 模型层提供）必须自行承担：
///  - writeLoading 串行化与 uid/canMutate 门（MusicMutation.cpp:188-200）；
///  - rename 所有权门 → PlaylistFormResult.rejected(status: 只能编辑自己创建的歌单)（:457-465）；
///  - siren 本地歌单分支与状态文案（:421-455）；
///  - rename 成功后的 verifiedTitle（:479）。
/// 本文件不直连网络，也不伪造这些结论。
abstract interface class PlaylistFormPort {
  Future<PlaylistFormResult> createPlaylist({required String name});

  Future<PlaylistFormResult> renamePlaylist({required String id, required String name});
}

/// 表格刷新端口（契约，由 library_modal 实现；本文件不实现表格，也不造数据）。
///
/// 语义逐条来自 MusicMutation.cpp:470-491 与 siren 分支 :432-433 / :441-442：
///  - [upsertCreated]：lists[2] = MusicData::unique(lists[2], {value})，且 value["creatorID"] = uid；
///  - [applyRenamed]：按 id 命中行替换 title = verifiedName，directory.item.title 同步；
///  - [reloadFromLocalCollections]：siren 分支 lists[2] = collections->playlists()；
///  - [syncTotals]：totals[2] = lists[2].size()。
abstract interface class SavedPlaylistTablePort {
  void upsertCreated(PlaylistFormRow row);

  void applyRenamed({required String id, required String verifiedTitle});

  void reloadFromLocalCollections();

  void syncTotals();
}

/// 提交成功后的回调载荷。
@immutable
class PlaylistFormCommit {
  const PlaylistFormCommit({
    required this.kind,
    required this.requestedName,
    required this.verifiedTitle,
    this.row,
  });

  final PlaylistFormKind kind;
  final String requestedName;

  /// rename 成功后的服务端确认名；create 时等于 requestedName（MusicMutation.cpp:475/479）。
  final String verifiedTitle;
  final PlaylistFormRow? row;
}

/// 稳定 Key，供命中/测试使用。
abstract final class PlaylistFormKeys {
  static const Key layer = Key('playlist-form-layer');
  static const Key nameField = Key('playlist-form-name');
  static const Key submit = Key('playlist-form-submit');
  static const Key back = Key('playlist-form-back');
  static const Key status = Key('playlist-form-status');
}

/// playlist-form 浮层。
///
/// 宿主把它挂在 stage 叠层的 Stack 里（对应 Overlay.qml 的 overlay 根），位置/不透明度由
/// [PlaylistFormView.modalOffset]/[PlaylistFormView.modalOpacity] 驱动（Overlay.qml:359/362）。
class PlaylistFormLayer extends StatefulWidget {
  const PlaylistFormLayer({
    super.key,
    required this.view,
    required this.port,
    this.table,
    this.onCloseModal,
    this.onCommitted,
  });

  final PlaylistFormView view;
  final PlaylistFormPort port;

  /// 可选：提交成功后的表格刷新端口（library_modal 实现）。
  final SavedPlaylistTablePort? table;

  /// "close-modal"（原生返回按钮 / ESC / 全局 ESC 最终都汇到这里）。
  final VoidCallback? onCloseModal;

  /// 提交成功回调（表格刷新语义由 [table] 承担；本回调只上报结果）。
  final void Function(PlaylistFormCommit commit)? onCommitted;

  @override
  State<PlaylistFormLayer> createState() => _PlaylistFormLayerState();
}

class _PlaylistFormLayerState extends State<PlaylistFormLayer> {
  final TextEditingController _name = TextEditingController();
  final FocusNode _focus = FocusNode(debugLabel: 'playlist-form-name');

  /// 层内防双击：端口调用在飞时忽略重复提交；writeLoading/uid/canMutate 门由端口承担。
  bool _submitting = false;

  /// 同帧回显：Qt 里这条文案由模型写进 music.status 后立即 changed()（MusicMutation.cpp:414-415
  /// 是同步路径）；端口化后模型状态由宿主注入，浮层保留一份同帧回显以免丢字。
  String? _statusOverride;

  @override
  void initState() {
    super.initState();
    if (widget.view.visible) {
      _focus.requestFocus(); // Overlay.qml:366-368 forceActiveFocus()
    }
  }

  @override
  void didUpdateWidget(covariant PlaylistFormLayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.view.visible != widget.view.visible) {
      // Overlay.qml:363-369 onVisibleChanged：无条件清空输入，仅变为可见时抢焦点。
      _name.clear();
      _statusOverride = null;
      if (widget.view.visible) {
        _focus.requestFocus();
      }
    }
    if (oldWidget.view.formKind != widget.view.formKind ||
        oldWidget.view.formPid != widget.view.formPid) {
      // 重新进入 create/rename：NativeHudMusic.cpp:315 formPID.clear() 后重开浮层，输入从空开始。
      _name.clear();
      _statusOverride = null;
    }
  }

  @override
  void dispose() {
    _name.dispose();
    _focus.dispose();
    super.dispose();
  }

  String get _statusLine => _statusOverride ?? widget.view.status;

  /// Overlay.qml:370-376 submit() + Engine.cpp:867-876 + MusicMutation.cpp:410-493 的接线。
  Future<void> _submit() async {
    final PlaylistFormView view = widget.view;
    if (_submitting) {
      // 在飞期间的重复提交被吞掉（层内防双击；writeLoading 门由端口承担）。
      return;
    }
    // 1) 校验（MusicMutation.cpp:411-420）——先于任何写门。
    final PlaylistFormValidation validation = PlaylistFormValidator.validateName(
      rawName: _name.text,
      provider: view.provider,
    );
    if (!validation.accepted) {
      _reportStatus(validation.message);
      return;
    }
    // 2) 写门由端口承担（MusicMutation.cpp:188-200）：siren 分支（:421-455）与 rename
    //    所有权门（:457-465）都在远端 mutate 之前；端口必须按序执行并返回 rejected(status)。
    //    本层不预先吞掉 writeLoading，否则会跳过端口里的这些 Qt 分支。
    setState(() => _submitting = true);
    final int generation = view.generation;
    PlaylistFormResult result;
    try {
      result = view.formKind == PlaylistFormKind.create
          ? await widget.port.createPlaylist(name: validation.trimmedName)
          : await widget.port.renamePlaylist(id: view.formPid, name: validation.trimmedName);
    } finally {
      if (mounted) {
        setState(() => _submitting = false);
      }
    }
    if (!mounted || generation != widget.view.generation) {
      return; // NativeHudController.cpp:173-177 token/generation 不符 → 结果丢弃
    }
    if (!result.ok) {
      _reportStatus(result.status);
      return;
    }
    final PlaylistFormRow? row = result.row;
    final SavedPlaylistTablePort? table = widget.table;
    final String verifiedTitle =
        result.verifiedTitle.isEmpty ? validation.trimmedName : result.verifiedTitle;
    if (table != null) {
      if (view.provider == 'siren') {
        table.reloadFromLocalCollections(); // MusicMutation.cpp:432-433 / :441-442
      } else if (view.formKind == PlaylistFormKind.create && row != null) {
        table.upsertCreated(row); // MusicMutation.cpp:470-476
      } else if (view.formKind == PlaylistFormKind.rename) {
        table.applyRenamed(id: view.formPid, verifiedTitle: verifiedTitle); // :478-490
      }
      table.syncTotals(); // MusicMutation.cpp:491
    }
    _statusOverride = null;
    widget.onCommitted?.call(
      PlaylistFormCommit(
        kind: view.formKind,
        requestedName: validation.trimmedName,
        verifiedTitle: verifiedTitle,
        row: row,
      ),
    );
    widget.onCloseModal?.call(); // NativeHudController.cpp:175-177 ok → closeModal()
  }

  void _reportStatus(String message) {
    setState(() => _statusOverride = message);
  }

  @override
  Widget build(BuildContext context) {
    final PlaylistFormView view = widget.view;
    if (!view.visible) {
      return const SizedBox.shrink();
    }
    final PlaylistFormLayout layout = view.portrait
        ? PlaylistFormLayout.portrait(viewport: view.viewport)
        : PlaylistFormLayout.stage(stageWidth: view.stageWidth, scale: view.stageScale);
    final double factor = view.portrait ? 1 : view.stageScale;
    return Opacity(
      opacity: view.modalOpacity.clamp(0.0, 1.0).toDouble(),
      child: Transform.translate(
        offset: Offset(0, view.modalOffset * factor),
        child: Stack(
          key: PlaylistFormKeys.layer,
          children: <Widget>[
            // 弹层框架由 chrome 层统一绘制（见文件头注释）；本层只画表单内容。
            _text(layout.fieldLabel, view.nameLabel, factor),
            _fieldBox(layout.scaled(layout.fieldBox)),
            _nameField(layout.scaled(layout.fieldRect), factor),
            _text(layout.hint, view.nameHint, factor),
            _statusLineWidget(layout, factor),
            _submitButton(layout.scaled(layout.submitButton), factor),
          ],
        ),
      ),
    );
  }

  Widget _text(HudTextSlot slot, String value, double factor) {
    if (value.isEmpty) {
      return const SizedBox.shrink();
    }
    return Positioned(
      left: slot.at.dx * factor,
      top: slot.at.dy * factor,
      child: Text(
        value,
        style: TextStyle(
          fontSize: slot.size * factor,
          fontWeight: slot.weight,
          color: widget.view.dark
              ? PlaylistFormSpec.hudInkDark
              : PlaylistFormSpec.hudInkLight,
        ),
      ),
    );
  }

  /// 状态行：limited(music.status, x+53, y+775, 12, usable-106)（NativeHud.cpp:77-79 + fit():48-76）。
  Widget _statusLineWidget(PlaylistFormLayout layout, double factor) {
    final String value = _statusLine;
    if (value.isEmpty) {
      return const SizedBox.shrink();
    }
    return Positioned(
      key: PlaylistFormKeys.status,
      left: layout.status.at.dx * factor,
      top: layout.status.at.dy * factor,
      width: layout.statusMaxWidth * factor,
      child: Text(
        value,
        maxLines: 1,
        overflow: TextOverflow.ellipsis, // fit() 的「…」语义
        style: TextStyle(
          fontSize: layout.status.size * factor,
          color: widget.view.dark
              ? PlaylistFormSpec.hudInkDark
              : PlaylistFormSpec.hudInkLight,
        ),
      ),
    );
  }

  Widget _fieldBox(Rect rect) => Positioned(
        left: rect.left,
        top: rect.top,
        width: rect.width,
        height: rect.height,
        child: ColoredBox(
          color: widget.view.dark ? PlaylistFormSpec.fieldFillDark : PlaylistFormSpec.fieldFillLight,
        ),
      );

  Widget _nameField(Rect rect, double factor) {
    final PlaylistFormView view = widget.view;
    return Positioned(
      left: rect.left,
      top: rect.top,
      width: rect.width,
      height: rect.height,
      child: Semantics(
        textField: true,
        label: PlaylistFormSpec.fieldAccessibleName, // Overlay.qml:398
        child: Focus(
          onKeyEvent: (FocusNode node, KeyEvent event) {
            if (event is KeyDownEvent && event.logicalKey == LogicalKeyboardKey.escape) {
              widget.onCloseModal?.call(); // Overlay.qml:406 Keys.onEscapePressed
              return KeyEventResult.handled;
            }
            return KeyEventResult.ignored;
          },
          child: TextField(
            key: PlaylistFormKeys.nameField,
            controller: _name,
            focusNode: _focus,
            enabled: view.fieldEnabled,
            maxLines: 1,
            showCursor: !view.performanceIdle, // Overlay.qml:394 cursorVisible && !idle
            textAlignVertical: TextAlignVertical.center, // Overlay.qml:391 AlignVCenter
            keyboardType: TextInputType.text, // Qt.ImhNone（Overlay.qml:397）
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => _submit(), // Overlay.qml:399-405 Keys.onReturnPressed
            inputFormatters: <TextInputFormatter>[
              PlaylistFormTextInputFormatter(view.fieldMaximumLength), // Overlay.qml:395
            ],
            style: TextStyle(
              fontSize: PlaylistFormSpec.fieldFontSize * factor,
              color: view.dark ? PlaylistFormSpec.fieldTextDark : PlaylistFormSpec.fieldTextLight,
            ),
            decoration: const InputDecoration(
              isDense: true,
              border: InputBorder.none,
              contentPadding: EdgeInsets.zero,
            ),
          ),
        ),
      ),
    );
  }

  Widget _submitButton(Rect rect, double factor) {
    final PlaylistFormView view = widget.view;
    return Positioned(
      left: rect.left,
      top: rect.top,
      width: rect.width,
      height: rect.height,
      child: Opacity(
        opacity: view.submitEnabled ? 1 : 0.5, // Overlay.qml:469
        child: Semantics(
          button: true,
          label: PlaylistFormSpec.submitAccessibleName, // Overlay.qml:477
          child: GestureDetector(
            key: PlaylistFormKeys.submit,
            behavior: HitTestBehavior.opaque,
            onTap: view.submitEnabled ? () => _submit() : null, // Overlay.qml:479-482 MouseArea
            child: ColoredBox(
              color: PlaylistFormSpec.submitFill, // Overlay.qml:468
              child: Center(
                child: Text(
                  PlaylistFormSpec.submitLabel, // Overlay.qml:472
                  style: TextStyle(
                    fontSize: PlaylistFormSpec.submitFontSize * factor,
                    color: PlaylistFormSpec.submitText,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
