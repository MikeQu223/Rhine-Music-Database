///  · 共享弹层外壳（modal shell）：frame / mask / motion / close / title 五段管线。
///
/// 归属（native 对照 Qt/src/NativeHudModal.cpp；本文件是这五段在 Flutter 侧的唯一 owner）：
///   - 绘制栈与整体透明度   ← NativeHudModal.cpp:83-84（save / alpha(opacity)）
///   - 遮罩 scrim           ← :163-165（只有通用路径画；search 更淡）
///   - 位移动画 translate   ← :166（遮罩在 translate 之前，所以遮罩不随面板滚动）
///   - 弹层边界 modalBounds ← NativeHud.cpp:140-159（含 containerLayout :160-166）
///   - 面板底 opaque panel  ← :171-172（detail-sort 用自己那一份 :129-130，无 calibration 标签，
///                            由 [ModalShellPolicy.darkPanelTagged] 保留该差异）
///   - 标题区               ← :188-202（category / title / subtitle / ← 返回）
///   - 关闭命中 close-modal ← :199-200（标题区）、:96（lyrics-offset 的框架关闭按钮）、
///                            :128（detail-sort 的舞台级关闭）
///   - SurfaceMotion        ← Qt/src/UiMotion.h:24-42 / UiMotion.cpp:86-120
///
/// 刻意不拥有（各 modal 自己的内容与语义，本文件不得吞并）：
///   - 各 modal 的行 / 按钮 / 字段 / 状态文案 / 业务 action（例如 "quality:set:*"、"music:sort:detail:*"）；
///   - modalTitle / modalSubtitle 的文案表（NativeHudModal.cpp:26-77）——由调用方算好后注入 [ModalShellSpec.title]；
///   - 关闭之后的状态迁移（NativeHudController.cpp:132-143 closeModal）、列表重置、登录取消；
///   - 任何存储写入、任何 I/O、任何生产宿主 / composition root 选择：本层是纯组件，不注册全局、不读全局。
///
/// 命中坐标约定（契约，勿改）：命令流与命中流是两个独立通道。面板内容与标题区都画在
/// translate(0, offset) 之后，但命中坐标一律不带 offset：Qt/qml/Overlay.qml:191 在 modal
/// 打开时给每个非 fixed 命中追加 state.modalOffset。所以本文件写 hit() 用未位移的舞台坐标；
/// 只有"点舞台任意处收起"的 detail-sort 目标把 offset 反号抵消（NativeHudModal.cpp:128 的
/// hit(0, -motion.offset, width, 1080, ...)），否则它会跟面板一起漂移。
///
/// 依赖边界：纯 Dart，只 import 契约层 helper（lib/hud/pages/chrome.dart）；不 import Flutter、
/// dart:io、存储或宿主，因此可以只做静态审查、不需要任何构建或运行验证。
///
/// 典型装配：sink / text 由宿主注入，spec 携带 modalId、舞台宽高、motion 的 opacity / offset、
/// 调用方算好的 title / subtitle，以及只画"自己的内容"的 content builder。
library;

import 'package:rhine_music_database/hud/pages/chrome.dart'
    show HudHit, HudSurfaceSink, HudTextPort, hudFill, hudHitRegion, hudOp, hudText;

//  冻结字面量（逐字对照 Qt 源码；改动即破坏 1:1）

/// 舞台高度：Qt 的遮罩与舞台级命中直接写 1080（NativeHudModal.cpp:128 / :163）。
/// HudStage.fromLogicalSize 已把任意窗口归一化到高 1080（lib/hud/protocol/hud_frame.dart:340-366），
/// 因此把 stageHeight 代入与 Qt 常量逐字等价；默认值就是这个常量。
const double kModalShellStageHeight = 1080.0;

/// 通用弹层顶边与高度：NativeHud.cpp:158 的 {left, 122, modalWidth, 836}。
const double kModalShellModalTop = 122.0;
const double kModalShellModalHeight = 836.0;

/// 通用弹层宽度上限与左右留白：NativeHud.cpp:153 的 min(1260, width - 100)。
const double kModalShellMaxWidth = 1260.0;
const double kModalShellHorizontalMargin = 100.0;

/// search 弹层的宽度夹取与贴右内缩：NativeHud.cpp:155 / :157（两处都是 59）。
const double kModalShellSearchWidthFloor = 760.0;
const double kModalShellSearchWidthCeiling = 1000.0;
const double kModalShellSearchWidthHalf = 0.5;
const double kModalShellSearchInset = 59.0;

/// detail-sort 相对 containerLayout 的偏移与尺寸：NativeHud.cpp:143。
const double kModalShellDetailSortLeftShift = 195.0;
const double kModalShellDetailSortTop = 391.0;
const double kModalShellDetailSortWidth = 240.0;
const double kModalShellDetailSortHeight = 184.0;

/// lyrics-source：NativeHud.cpp:147（注释 :146「来源菜单」）。
const double kModalShellLyricsSourceLeftRatio = 0.56;
const double kModalShellLyricsSourceLeftShift = 156.0;
const double kModalShellLyricsSourceTop = 674.0;
const double kModalShellLyricsSourceWidth = 232.0;
const double kModalShellLyricsSourceHeight = 232.0;

/// lyrics-offset：NativeHud.cpp:151（注释 :150「偏移设置」）。
const double kModalShellLyricsOffsetLeftRatio = 0.56;
const double kModalShellLyricsOffsetTop = 690.0;
const double kModalShellLyricsOffsetWidth = 320.0;
const double kModalShellLyricsOffsetHeight = 216.0;

/// containerLayout：NativeHud.cpp:160-166 + NativeHud.h:37-47 的 Layout 默认值。
const double kModalShellContainerLeft = 40.0;
const double kModalShellSidebarRatio = 0.23;
const double kModalShellSidebarInset = 40.0;
const double kModalShellSidebarMin = 250.0;
const double kModalShellSidebarMax = 340.0;
const double kModalShellContainerGutter = 36.0;
const double kModalShellContainerRightInset = 40.0;

/// 标题区几何：NativeHudModal.cpp:198-202。
const double kModalShellHeaderInset = 53.0;
const double kModalShellCategoryTop = 37.0;
const double kModalShellCategorySize = 11.0;
const double kModalShellCategorySizeSettings = 14.0;
const double kModalShellTitleTop = 91.0;
const double kModalShellTitleSize = 38.0;
const double kModalShellSubtitleTop = 147.0;
const double kModalShellSubtitleSize = 15.0;
const double kModalShellSubtitleSizeSettings = 18.0;
const double kModalShellBackRightInset = 220.0;
const double kModalShellBackTop = 18.0;
const double kModalShellBackWidth = 167.0;
const double kModalShellBackHeight = 54.0;
const double kModalShellBackSize = 20.0;

/// 标题区分类：NativeHudModal.cpp:188-198。
const String kModalShellCategoryPrefix = 'RHINE LAB / MUSIC DATABASE / ';
const String kModalShellCategoryDefault = 'MUSIC DIRECTORY';
const String kModalShellCategorySettings = 'SYSTEM PREFERENCES';
const String kModalShellCategoryDesktopLyrics = 'DESKTOP LYRICS';
const String kModalShellCategoryPlayer = 'AUDIO TERMINAL';
const String kModalShellCategoryQuality = 'AUDIO SPECIFICATION';

/// 关闭动作：NativeHudController.cpp:686-687；desktop-lyrics 是唯一例外（NativeHudModal.cpp:199-200）。
const String kModalShellCloseAction = 'close-modal';
const String kModalShellDesktopLyricsBackAction = 'desktop-lyrics:back';
const String kModalShellBackLabel = '← 返回';

/// lyrics-offset 的框架关闭按钮：:87 的 x = bounds.x() + 16，:96 的
/// button("关闭", x + 232, y + 8, 56, 36, "close-modal", 13)。
/// 它属于关闭管线（不随歌词状态变化），因此归外壳；内容 builder 不再重复画。
const double kModalShellBareCloseLeftInset = 248.0;
const double kModalShellBareCloseTopInset = 8.0;
const double kModalShellBareCloseWidth = 56.0;
const double kModalShellBareCloseHeight = 36.0;
const double kModalShellBareCloseSize = 13.0;
const String kModalShellBareCloseLabel = '关闭';

/// detail-sort 舞台级关闭命中的标签：NativeHudModal.cpp:128。
const String kModalShellDismissLabel = '关闭排序菜单';

/// 弹层 id：Qt 里就是 modal 字符串字面量。本文件只用它们判断几何与管线策略。
const String kModalShellSearchModal = 'search';
const String kModalShellSettingsModal = 'settings';
const String kModalShellDesktopLyricsModal = 'desktop-lyrics';
const String kModalShellPlayerModal = 'player';
const String kModalShellDiscoverModal = 'discover';
const String kModalShellQualityModal = 'quality';
const String kModalShellLyricsOffsetModal = 'lyrics-offset';
const String kModalShellLyricsSourceModal = 'lyrics-source';
const String kModalShellDetailSortModal = 'detail-sort';

// 颜色（Qt 的 QJsonArray 复合色原样搬，不做 gamma 变换）

/// 遮罩色：NativeHudModal.cpp:163-165。search 更淡（0.15 / 0.12 对 0.6 / 0.45）。
List<Object?> modalShellScrimColor({required bool dark, required bool search}) => dark
    ? <Object?>[17.0 / 255, 24.0 / 255, 27.0 / 255, search ? 0.15 : 0.6]
    : <Object?>[227.0 / 255, 224.0 / 255, 215.0 / 255, search ? 0.12 : 0.45];

/// 面板底色：NativeHudModal.cpp:171-172 / :146 / :91。
/// detail-sort 在 :130 少了 "calibratedWhite" 标签，故由 tagged 区分（见 [ModalShellPolicy.darkPanelTagged]）。
List<Object?> modalShellPanelColor({required bool dark, required bool tagged}) => dark
    ? (tagged ? <Object?>[0.15, 0.15, 0.15, 1, 'calibratedWhite'] : <Object?>[0.15, 0.15, 0.15, 1])
    : <Object?>[0.929, 0.922, 0.894, 1];

/// 弹层控件底色（button 在 m_modalControls 下的 tint，NativeHud.cpp:115-116）。
/// 外壳只给标题区那个 ← 返回 用；内容里的按钮仍归各 modal 自己画。
List<Object?> modalShellControlTint({required bool dark}) =>
    dark ? <Object?>[0.55, 0.59, 0.46, 0.13] : <Object?>[0.44, 0.49, 0.36, 0.1];

// 边界

/// 弹层矩形（舞台坐标，未叠加 motion.offset）。相当于 Qt 的 QRectF。
final class ModalShellBounds {
  const ModalShellBounds({
    required this.left,
    required this.top,
    required this.width,
    required this.height,
  });

  final double left;
  final double top;
  final double width;
  final double height;

  double get right => left + width;
  double get bottom => top + height;

  @override
  bool operator ==(Object other) =>
      other is ModalShellBounds &&
      other.left == left &&
      other.top == top &&
      other.width == width &&
      other.height == height;

  @override
  int get hashCode => Object.hash(left, top, width, height);

  @override
  String toString() => 'ModalShellBounds(' + left.toString() + ', ' + top.toString() + ', '
      + width.toString() + 'x' + height.toString() + ')';
}

/// containerLayout 的结果（只有外壳与 detail-sort 需要，故不暴露 top / rowsY 等列布局字段）。
final class ModalShellContainerLayout {
  const ModalShellContainerLayout({
    required this.left,
    required this.sidebar,
    required this.x,
    required this.width,
  });

  final double left;
  final double sidebar;
  final double x;
  final double width;
}

/// Qt NativeHud::containerLayout（NativeHud.cpp:160-166）。
ModalShellContainerLayout modalShellContainerLayout(double stageWidth) {
  final double sidebar = _clamp(
    stageWidth * kModalShellSidebarRatio - kModalShellSidebarInset,
    kModalShellSidebarMin,
    kModalShellSidebarMax,
  ); // :162
  final double x = kModalShellContainerLeft + sidebar + kModalShellContainerGutter; // :163
  return ModalShellContainerLayout(
    left: kModalShellContainerLeft,
    sidebar: sidebar,
    x: x,
    width: stageWidth - x - kModalShellContainerRightInset, // :164
  );
}

/// Qt NativeHud::modalBounds（NativeHud.cpp:140-159）1:1 移植。
///
/// 特殊弹层（lyrics-offset / lyrics-source / detail-sort）走各自的小矩形，通用弹层走
/// 居中 1260 或 search 的贴右夹取；两条路都仍由外壳统一画面板底与关闭命中
/// （特殊弹层只是不画遮罩、不走标题区）。
ModalShellBounds modalShellBounds({required String modalId, required double stageWidth}) {
  if (modalId == kModalShellDetailSortModal) {
    final ModalShellContainerLayout layout = modalShellContainerLayout(stageWidth);
    return ModalShellBounds(
      left: layout.x + kModalShellDetailSortLeftShift,
      top: kModalShellDetailSortTop,
      width: kModalShellDetailSortWidth,
      height: kModalShellDetailSortHeight,
    ); // :143
  }
  if (modalId == kModalShellLyricsSourceModal) {
    return ModalShellBounds(
      left: stageWidth * kModalShellLyricsSourceLeftRatio + kModalShellLyricsSourceLeftShift,
      top: kModalShellLyricsSourceTop,
      width: kModalShellLyricsSourceWidth,
      height: kModalShellLyricsSourceHeight,
    ); // :147
  }
  if (modalId == kModalShellLyricsOffsetModal) {
    return ModalShellBounds(
      left: stageWidth * kModalShellLyricsOffsetLeftRatio,
      top: kModalShellLyricsOffsetTop,
      width: kModalShellLyricsOffsetWidth,
      height: kModalShellLyricsOffsetHeight,
    ); // :151
  }
  double modalWidth = _min(kModalShellMaxWidth, stageWidth - kModalShellHorizontalMargin); // :153
  if (modalId == kModalShellSearchModal) {
    modalWidth = _min(
      stageWidth - kModalShellHorizontalMargin,
      _max(
        kModalShellSearchWidthFloor,
        _min(
          kModalShellSearchWidthCeiling,
          stageWidth * kModalShellSearchWidthHalf - kModalShellSearchInset,
        ),
      ),
    ); // :155
  }
  final double left = modalId == kModalShellSearchModal
      ? stageWidth - modalWidth - kModalShellSearchInset
      : (stageWidth - modalWidth) / 2; // :157
  return ModalShellBounds(
    left: left,
    top: kModalShellModalTop,
    width: modalWidth,
    height: kModalShellModalHeight,
  ); // :158
}

// 管线策略

/// 一个弹层的管线策略：外壳只回答"哪几段要画"，不回答"内容长什么样"。
final class ModalShellPolicy {
  const ModalShellPolicy({
    required this.modalId,
    required this.paintsStageScrim,
    required this.usesTitleBand,
    required this.dismissesOnStageTap,
    required this.dismissLabel,
    required this.bareCloseAffordance,
    required this.backAction,
    required this.category,
    required this.search,
    required this.darkPanelTagged,
  });

  /// 从 modal id 派生策略，逐条对应 Qt 的分支：
  ///   - :85-160 三个特殊弹层在 :163 之前 return ⇒ 不画遮罩、不走标题区；
  ///   - :175-187 player / discover 画完自己的内部就 return ⇒ 有遮罩、有面板底，但不走标题区；
  ///   - :128 detail-sort 额外要一个舞台级关闭命中（唯一的"点空白处收起"）。
  factory ModalShellPolicy.forModal(String modalId) {
    final bool bare = _isBareModal(modalId);
    return ModalShellPolicy(
      modalId: modalId,
      paintsStageScrim: !bare,
      usesTitleBand:
          !bare && modalId != kModalShellPlayerModal && modalId != kModalShellDiscoverModal,
      dismissesOnStageTap: modalId == kModalShellDetailSortModal,
      dismissLabel: kModalShellDismissLabel,
      bareCloseAffordance: modalId == kModalShellLyricsOffsetModal,
      backAction: modalId == kModalShellDesktopLyricsModal
          ? kModalShellDesktopLyricsBackAction
          : kModalShellCloseAction,
      category: _categoryFor(modalId),
      search: modalId == kModalShellSearchModal,
      darkPanelTagged: modalId != kModalShellDetailSortModal,
    );
  }

  final String modalId;

  /// 是否画全舞台遮罩（:163-165）。三个特殊弹层为 false——Qt 在 :120 / :140 / :160 就 return 了。
  final bool paintsStageScrim;

  /// 是否画通用标题区（:188-202）。player / discover 与三个特殊弹层为 false。
  final bool usesTitleBand;

  /// 是否发舞台级关闭命中（仅 detail-sort，:128）。
  final bool dismissesOnStageTap;

  /// 舞台级关闭命中的 label（:128 的 "关闭排序菜单"）。
  final String dismissLabel;

  /// 是否由外壳画一个"框架关闭按钮"。只有 lyrics-offset 有（:96）；lyrics-source 与
  /// detail-sort 在 Qt 里没有按钮式关闭（detail-sort 用舞台级命中 :128，lyrics-source 交给输入层
  /// Escape 分发，NativeHudController.cpp:913-921）。
  final bool bareCloseAffordance;

  /// 标题区 ← 返回 的 action：close-modal；desktop-lyrics 例外走 desktop-lyrics:back（:199-200）。
  final String backAction;

  /// 标题区分类名（:188-197）。player 的 "AUDIO TERMINAL" 在 Qt 里是死代码（:175-180 已 return），
  /// 这里照样保留映射，方便将来 player 面板改用标题区时 1:1 对齐。
  final String category;

  /// 是否是 search 弹层（只影响遮罩透明度与宽度夹取）。
  final bool search;

  /// dark 面板色是否带 "calibratedWhite" 标签（detail-sort 不带，见 :130 与 :171-172 的差异）。
  final bool darkPanelTagged;

  /// 遮罩色（:163-165）。
  List<Object?> scrimColor({required bool dark}) =>
      modalShellScrimColor(dark: dark, search: search);

  /// 面板底色（:171-172 / :146 / :91；detail-sort 见 :130）。
  List<Object?> panelColor({required bool dark}) =>
      modalShellPanelColor(dark: dark, tagged: darkPanelTagged);
}

bool _isBareModal(String modalId) =>
    modalId == kModalShellLyricsOffsetModal ||
    modalId == kModalShellLyricsSourceModal ||
    modalId == kModalShellDetailSortModal;

/// NativeHudModal.cpp:188-197 的分类映射（default 在 :188）。
String _categoryFor(String modalId) {
  if (modalId == kModalShellSettingsModal) return kModalShellCategorySettings;
  if (modalId == kModalShellDesktopLyricsModal) return kModalShellCategoryDesktopLyrics;
  if (modalId == kModalShellPlayerModal) return kModalShellCategoryPlayer;
  if (modalId == kModalShellQualityModal) return kModalShellCategoryQuality;
  return kModalShellCategoryDefault;
}

// 位移动画（SurfaceMotion 1:1）

/// Qt UiMotion::SurfaceMotion 的逐行移植（UiMotion.h:24-42 / UiMotion.cpp:86-120）。
///
/// 时间单位是秒；offset 是界面逻辑坐标偏移。进入 0.3s、收起 0.2s、进入目标 offset 0、
/// 收起目标 offset 8、初始 offset 12，全部与 Qt 默认值一致。
/// 外壳只持有并采样，不驱动时钟：宿主每个 tick 调 [sample]，收起曲线走完（[finished]）
/// 之后才允许释放面板（NativeHud.cpp:263-266 的语义）。
final class ModalShellMotion {
  /// 当前采样值（对应 Qt 的公开字段 opacity / offset / duration）。
  double opacity = 0;
  double offset = 12;
  double duration = 0;

  double _fromOpacity = 0;
  double _fromOffset = 12;
  double _targetOpacity = 0;
  double _targetOffset = 12;
  double _start = 0;
  bool _entering = true;

  /// Qt finished()（UiMotion.h:28-30）：duration 归零才算走完。
  bool get finished => duration == 0;

  /// Qt sample(time)（UiMotion.cpp:86-98）：按 bezier 进度插值透明度与偏移。
  void sample(double time) {
    if (duration <= 0) return;
    final double progress = _clamp((time - _start) / duration, 0, 1);
    final double amount = _bezier(
      progress,
      _entering ? 0.22 : 0.4,
      _entering ? 1 : 0,
      _entering ? 0.36 : 1,
      1,
    );
    opacity = _fromOpacity + (_targetOpacity - _fromOpacity) * amount;
    offset = _fromOffset + (_targetOffset - _fromOffset) * amount;
    if (progress >= 1) duration = 0;
  }

  /// Qt set(shown, time, reduced)（UiMotion.cpp:101-120）：先采样旧过渡再换目标，
  /// 这样快速开关弹窗时透明度与偏移是接续的（:100 注释）。
  /// reduced 为真时直接吸附到目标并把 duration 归零（无动画）。
  void set(bool shown, double time, {bool reduced = false}) {
    sample(time);
    _fromOpacity = opacity;
    _fromOffset = offset;
    _targetOpacity = shown ? 1 : 0;
    _targetOffset = shown ? 0 : 8;
    _entering = shown;
    _start = time;
    if (reduced) {
      duration = 0;
    } else {
      duration = shown ? 0.3 : 0.2;
    }
    if (reduced) {
      opacity = _targetOpacity;
      offset = _targetOffset;
    }
  }
}

/// Qt UiMotion.cpp:7-22 的 cubic bezier：先 24 次二分求 x 对应的 t，再取 y 分量。
double _bezier(double x, double x1, double y1, double x2, double y2) {
  double lower = 0;
  double upper = 1;
  for (int index = 0; index < 24; index += 1) {
    final double t = (lower + upper) / 2;
    if (_bezierComponent(t, x1, x2) < x) {
      lower = t;
    } else {
      upper = t;
    }
  }
  return _bezierComponent((lower + upper) / 2, y1, y2);
}

double _bezierComponent(double t, double a, double b) =>
    3 * (1 - t) * (1 - t) * t * a + 3 * (1 - t) * t * t * b + t * t * t;

double _min(double a, double b) => a < b ? a : b;

double _max(double a, double b) => a > b ? a : b;

double _clamp(double value, double lower, double upper) {
  if (value < lower) return lower;
  if (value > upper) return upper;
  return value;
}

// 输入 / 输出

/// 一次弹层绘制的输入。外壳只消费它，不读任何全局状态、不查音乐模型。
final class ModalShellSpec {
  const ModalShellSpec({
    required this.modalId,
    required this.stageWidth,
    this.stageHeight = kModalShellStageHeight,
    this.dark = false,
    this.opacity = 1,
    this.offset = 0,
    this.title = '',
    this.subtitle = '',
    this.content,
  });

  /// Qt 的 modal 字符串（'settings' / 'confirm' / 'lyrics-offset' …）。
  final String modalId;

  /// 舞台宽（HudStage.width，已是 1080 高归一化后的宽度）。
  final double stageWidth;

  /// 舞台高，恒为 [kModalShellStageHeight]；留参数只为把"给定舞台宽高"写进契约。
  final double stageHeight;

  /// Qt 成员 dark（决定遮罩 / 面板 / 控件底色）。
  final bool dark;

  /// 当前 motion.opacity（ModalShellMotion.opacity，由宿主采样后传入）。
  final double opacity;

  /// 当前 motion.offset（ModalShellMotion.offset）。
  final double offset;

  /// 标题区主标题（Qt modalTitle，调用方计算）。usesTitleBand 为 false 时忽略。
  final String title;

  /// 标题区副标题（Qt modalSubtitle，调用方计算）。usesTitleBand 为 false 时忽略。
  final String subtitle;

  /// 面板内容 builder；null = 只画外壳（没有内容）。
  final ModalShellContentBuilder? content;
}

/// 面板内容 builder。收到的 [ModalShellBody] 已经处于 save / alpha / translate 之后，
/// 也已经有遮罩、面板底、标题区；builder 只画自己的内容，不得再发 save / restore /
/// alpha / translate / 遮罩 / 面板底 / 标题区，也不得再造第二个 close-modal。
typedef ModalShellContentBuilder = void Function(ModalShellBody body);

/// 绘制过程中交给内容 builder 的上下文。
final class ModalShellBody {
  const ModalShellBody({
    required this.sink,
    required this.text,
    required this.hits,
    required this.policy,
    required this.bounds,
    required this.stageWidth,
    required this.stageHeight,
    required this.dark,
    required this.offset,
  });

  final HudSurfaceSink sink;
  final HudTextPort text;

  /// 本次绘制的命中表（每次 build 新建，等价 Qt 的 hits = {}）。
  final ModalShellHitTable hits;

  final ModalShellPolicy policy;

  /// 面板矩形（舞台坐标，未叠加 offset）。
  final ModalShellBounds bounds;

  final double stageWidth;
  final double stageHeight;
  final bool dark;

  /// 当前 motion.offset：内容的绘制已含位移，只有需要构造"静止"命中时才用它反号
  /// （detail-sort 的舞台级关闭就是这种做法，NativeHudModal.cpp:128）。
  final double offset;

  /// 追加一条命中到本次命中表；坐标按未位移的舞台坐标写（见文件头命中坐标约定）。
  void hit(double x, double y, double width, double height, String action, [String? label]) {
    hudHitRegion(hits, x, y, width, height, action, label);
  }
}

/// build() 的返回值：给测试 / 宿主断言策略与边界，不必解析命令流。
final class ModalShellResult {
  const ModalShellResult({required this.policy, required this.bounds, required this.hits});

  final ModalShellPolicy policy;
  final ModalShellBounds bounds;

  /// 命中按发射顺序，与 Qt hits 顺序一致（append-only，不排序、不去重）。
  final List<HudHit> hits;
}

/// 追加式命中表，等价 Qt 的 hits = {}（NativeHudModal.cpp:125 / :147 / :173）。
///
/// 命令只能写宿主的 [HudSurfaceSink]；本表只收命中，收到命令直接抛错而不是静默丢弃。
final class ModalShellHitTable implements HudSurfaceSink {
  final List<HudHit> _entries = <HudHit>[];

  /// 只读快照（顺序即语义，见 lib/hud/protocol/hud_hit.dart:14-18）。
  List<HudHit> get entries => List<HudHit>.unmodifiable(_entries);

  int get length => _entries.length;

  @override
  void hit(HudHit hit) {
    _entries.add(hit);
  }

  @override
  void op(List<Object?> command) {
    throw UnsupportedError('ModalShellHitTable 只接收命中，命令请写宿主 sink：' + command.toString());
  }
}

// 外壳

/// 共享弹层外壳：一次 [build] 恰好发一轮
/// save → alpha → [遮罩] → translate → 面板底 → [舞台关闭命中] → [标题区] → 内容 → restore，
/// 顺序与 NativeHudModal.cpp:83-256 一致。
final class ModalShell {
  const ModalShell({required this.sink, required this.text, required this.spec});

  final HudSurfaceSink sink;
  final HudTextPort text;
  final ModalShellSpec spec;

  /// 画一次弹层，返回本轮策略 / 边界 / 命中快照。
  ModalShellResult build() {
    final ModalShellPolicy policy = ModalShellPolicy.forModal(spec.modalId);
    final ModalShellBounds bounds = modalShellBounds(
      modalId: spec.modalId,
      stageWidth: spec.stageWidth,
    );
    final ModalShellHitTable hits = ModalShellHitTable();

    hudOp(sink, <Object?>['save']); // :83
    hudOp(sink, <Object?>['alpha', spec.opacity]); // :84
    if (policy.paintsStageScrim) {
      // :163-165：遮罩画在 translate 之前，所以面板滚动时遮罩不动。
      hudFill(sink, policy.scrimColor(dark: spec.dark), 0, 0, spec.stageWidth, spec.stageHeight);
    }
    hudOp(sink, <Object?>['translate', 0, spec.offset]); // :166
    hudFill(
      sink,
      policy.panelColor(dark: spec.dark),
      bounds.left,
      bounds.top,
      bounds.width,
      bounds.height,
    ); // :171-172
    if (policy.dismissesOnStageTap) {
      // :128：offset 反号，抵消 Overlay.qml:191 对非 fixed 命中的 modalOffset 追加，
      // 让这条舞台级关闭命中始终覆盖整个舞台。
      hudHitRegion(
        hits,
        0,
        -spec.offset,
        spec.stageWidth,
        spec.stageHeight,
        kModalShellCloseAction,
        policy.dismissLabel,
      );
    }
    if (policy.usesTitleBand) {
      _titleBand(policy, bounds, hits);
    } else if (policy.bareCloseAffordance) {
      _bareClose(bounds, hits);
    }
    final ModalShellContentBuilder? content = spec.content;
    if (content != null) {
      content(
        ModalShellBody(
          sink: sink,
          text: text,
          hits: hits,
          policy: policy,
          bounds: bounds,
          stageWidth: spec.stageWidth,
          stageHeight: spec.stageHeight,
          dark: spec.dark,
          offset: spec.offset,
        ),
      );
    }
    hudOp(sink, <Object?>['restore']); // :255-256
    return ModalShellResult(policy: policy, bounds: bounds, hits: hits.entries);
  }

  /// NativeHudModal.cpp:188-202：分类行 → ← 返回 → 标题 → 副标题。
  void _titleBand(ModalShellPolicy policy, ModalShellBounds bounds, ModalShellHitTable hits) {
    final bool settings = spec.modalId == kModalShellSettingsModal;
    final double x = bounds.left;
    final double y = bounds.top;
    hudText(
      sink,
      kModalShellCategoryPrefix + policy.category,
      x + kModalShellHeaderInset,
      y + kModalShellCategoryTop,
      settings ? kModalShellCategorySizeSettings : kModalShellCategorySize,
      dark: spec.dark,
    ); // :198
    _modalControlButton(
      hits,
      kModalShellBackLabel,
      x + bounds.width - kModalShellBackRightInset,
      y + kModalShellBackTop,
      kModalShellBackWidth,
      kModalShellBackHeight,
      policy.backAction,
      kModalShellBackSize,
      'demibold',
    ); // :199-200
    hudText(
      sink,
      spec.title,
      x + kModalShellHeaderInset,
      y + kModalShellTitleTop,
      kModalShellTitleSize,
      weight: 'demibold',
      dark: spec.dark,
    ); // :201
    hudText(
      sink,
      spec.subtitle,
      x + kModalShellHeaderInset,
      y + kModalShellSubtitleTop,
      settings ? kModalShellSubtitleSizeSettings : kModalShellSubtitleSize,
      dark: spec.dark,
    ); // :202
  }

  /// 无标题区弹层的框架关闭按钮（NativeHudModal.cpp:96）：位置相对面板，action 固定 close-modal。
  void _bareClose(ModalShellBounds bounds, ModalShellHitTable hits) {
    _modalControlButton(
      hits,
      kModalShellBareCloseLabel,
      bounds.left + kModalShellBareCloseLeftInset,
      bounds.top + kModalShellBareCloseTopInset,
      kModalShellBareCloseWidth,
      kModalShellBareCloseHeight,
      kModalShellCloseAction,
      kModalShellBareCloseSize,
      'regular',
    ); // :96
  }

  /// NativeHud::button 在 m_modalControls 下的那一支（NativeHud.cpp:110-120）：
  /// 先命中，再 tint，再按 width - inset*2 拟合后画文字。
  ///
  /// 注意 Qt 的 quirk：:118 调 fit() 时没传 weight，所以即使标签按 demibold 画，
  /// 拟合宽度仍按 regular 量。这里照抄，保证截断点与 Qt 逐字一致。
  void _modalControlButton(
    ModalShellHitTable hits,
    String label,
    double x,
    double y,
    double width,
    double height,
    String action,
    double size,
    String weight,
  ) {
    hudHitRegion(hits, x, y, width, height, action, label); // :112
    final double inset = _min(10, width / 8); // :113
    hudFill(sink, modalShellControlTint(dark: spec.dark), x, y, width, height); // :115-116
    hudText(
      sink,
      text.fit(label, size, width - inset * 2),
      x + inset,
      y + (height - size) / 2 - 4,
      size,
      weight: weight,
      dark: spec.dark,
    ); // :118-119
  }
}
