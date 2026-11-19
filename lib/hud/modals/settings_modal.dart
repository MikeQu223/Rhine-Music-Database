//  — 设置模态：七区布局 / 五类自定义区渲染 / 模态框架 / 滚动 / 编辑浮层几何
//
// 证据（全部来自 Qt 源，不使用旧 Flutter UI，不凭记忆）：
//   Qt/src/SettingsSchema.cpp:693-703     七区定义（id / order / 中英标题 / 自定义渲染器 / 高度）
//   Qt/src/SettingsCard.cpp:9-19          布局常量 46/24/66/76/50/28/14/300/16/50/60
//   Qt/src/SettingsCard.cpp:36-45         表头：序号 + 标题 + 下划线
//   Qt/src/SettingsCard.cpp:239-292       layout() 逐条算法
//   Qt/src/SettingsCard.cpp:294-327       paint() 逐条算法
//   Qt/src/NativeHudSettings.cpp:39-77    模型构建（跳过不可见分区 / 按 order 升序）
//   Qt/src/NativeHudSettings.cpp:96-107   视口 = bounds.x+40, bounds.y+176, width-80, 660
//   Qt/src/NativeHudSettings.cpp:163-225  设置面板绘制 + 滚动轨道 + 上/下滚动按钮
//   Qt/src/NativeHudSettings.cpp:227-379  五类自定义渲染内容
//   Qt/src/NativeHudSettings.cpp:492-525  恢复默认设置语义边界
//   Qt/src/NativeHudModal.cpp:188-202     模态框架：类别标签 / 标题 / 副标题 / 返回按钮
//   Qt/src/NativeHudModal.cpp:5-24        平台候选表（5 项，非 LocalMusic 移除 local）
//   Qt/src/NativeHudModal.cpp:259-291     平台选择器几何（gap 12 / 190 / 66 / provider:<id>）
//   Qt/src/NativeHud.h:114-139            SettingsViewportTop=176, Bottom=836, contentBottom
//   Qt/src/NativeHudInput.cpp:9-36        滚轮步长 66 与命中窗口
//   Qt/src/HudScroll.h:1-100              maximum / clampOffset / applyWheel / rail / clipHits
//   Qt/qml/Overlay.qml:563-602            设置编辑浮层外观与位置
//   Qt/qml/PerformancePanel.qml:1-150     性能面板本体（标题 / 详情 / 四按钮）
//   /docs/flutter-migration/contracts/settings-platform.md §1/§4/§5/§8/§10/§13（冻结契约）
//
// 直接复用 A1 冻结原子 package:rhine_music_database/hud/widgets/settings_row.dart，不复制其常量。

import 'dart:math' as math;
import 'dart:ui' show Offset, Rect, Size;

import 'package:rhine_music_database/hud/widgets/settings_row.dart';

// 1. 平台能力矩阵 —— 契约 §8 / Qt/src/PlatformFeatures.h:1-25

/// 契约 §8 的五项平台能力。默认值刻意不写成单一平台常量：
/// 每个命名构造器逐条对齐 PlatformFeatures.h 的宏分支，调用方按平台选择。
class PlatformCapabilities {
  const PlatformCapabilities({
    required this.officialPlayback,
    required this.localMusic,
    required this.applicationVolume,
    required this.desktopWindowControls,
    required this.desktopLyrics,
  });

  /// OfficialPlayback：Android/iOS false；Windows/macOS/Linux true。
  final bool officialPlayback;

  /// LocalMusic：Android/iOS false；Windows/macOS/Linux true（决定 local 候选是否保留）。
  final bool localMusic;

  /// ApplicationVolume：Android/iOS false；Windows/macOS/Linux true。
  final bool applicationVolume;

  /// DesktopWindowControls：Android/iOS false；Windows/macOS/Linux true。
  final bool desktopWindowControls;

  /// DesktopLyrics：Android/iOS/Linux false；Windows/macOS true。
  final bool desktopLyrics;

  /// PlatformFeatures.h: RHINE_MOBILE 分支 —— 四项 false。
  const PlatformCapabilities.android()
      : this(
          officialPlayback: false,
          localMusic: false,
          applicationVolume: false,
          desktopWindowControls: false,
          desktopLyrics: false,
        );

  /// PlatformFeatures.h: RHINE_MOBILE 分支 —— 四项 false。
  const PlatformCapabilities.iOS()
      : this(
          officialPlayback: false,
          localMusic: false,
          applicationVolume: false,
          desktopWindowControls: false,
          desktopLyrics: false,
        );

  /// PlatformFeatures.h: 桌面分支 —— 四项 true，DesktopLyrics 亦 true。
  const PlatformCapabilities.windows()
      : this(
          officialPlayback: true,
          localMusic: true,
          applicationVolume: true,
          desktopWindowControls: true,
          desktopLyrics: true,
        );

  /// PlatformFeatures.h: 桌面分支 —— 四项 true，DesktopLyrics 亦 true。
  const PlatformCapabilities.macOS()
      : this(
          officialPlayback: true,
          localMusic: true,
          applicationVolume: true,
          desktopWindowControls: true,
          desktopLyrics: true,
        );

  /// PlatformFeatures.h: 桌面分支四项 true，但 DesktopLyrics 在 Linux 恒 false。
  const PlatformCapabilities.linux()
      : this(
          officialPlayback: true,
          localMusic: true,
          applicationVolume: true,
          desktopWindowControls: true,
          desktopLyrics: false,
        );

  PlatformCapabilities copyWith({
    bool? officialPlayback,
    bool? localMusic,
    bool? applicationVolume,
    bool? desktopWindowControls,
    bool? desktopLyrics,
  }) =>
      PlatformCapabilities(
        officialPlayback: officialPlayback ?? this.officialPlayback,
        localMusic: localMusic ?? this.localMusic,
        applicationVolume: applicationVolume ?? this.applicationVolume,
        desktopWindowControls: desktopWindowControls ?? this.desktopWindowControls,
        desktopLyrics: desktopLyrics ?? this.desktopLyrics,
      );

  @override
  bool operator ==(Object other) =>
      other is PlatformCapabilities &&
      other.officialPlayback == officialPlayback &&
      other.localMusic == localMusic &&
      other.applicationVolume == applicationVolume &&
      other.desktopWindowControls == desktopWindowControls &&
      other.desktopLyrics == desktopLyrics;

  @override
  int get hashCode => Object.hash(officialPlayback, localMusic, applicationVolume,
      desktopWindowControls, desktopLyrics);

  @override
  String toString() => 'PlatformCapabilities(officialPlayback: $officialPlayback, localMusic: $localMusic, applicationVolume: $applicationVolume, desktopWindowControls: $desktopWindowControls, desktopLyrics: $desktopLyrics)';
}

// 2. 七区定义（契约 §1 硬冻结；SettingsSchema.cpp:693-703）

/// 七区 id（顺序即契约 §1 的枚举顺序）。
enum SettingsSectionId { provider, preferences, performance, storage, update, project, footer }

/// 自定义渲染器名字常量（Qt SettingsSchema 的 customRenderer 字段逐字）。
class SettingsCustomRenderers {
  const SettingsCustomRenderers._();

  static const String providerCard = 'provider-card';
  static const String performance = 'performance';
  static const String storage = 'storage';
  static const String update = 'update';
  static const String defaults = 'defaults';
}

/// SettingsSchema.cpp:693-703 的 SettingsSection：id / number / order / 中英标题 /
/// customRenderer / customHeight / alwaysVisible。
class SettingsSectionSpec {
  const SettingsSectionSpec({
    required this.id,
    required this.number,
    required this.order,
    required this.titleEn,
    required this.titleZh,
    required this.customRenderer,
    required this.customHeight,
    this.alwaysVisible = true,
  });

  final SettingsSectionId id;

  /// 表头序号 1..7。
  final int number;

  /// 排序键（契约 §1：10/20/30/40/50/60/70）。
  final int order;

  final String titleEn;
  final String titleZh;

  /// 空串表示普通行分区（Preferences / Project）。
  final String customRenderer;

  /// 自定义区体高；普通行分区为 0。
  final double customHeight;

  /// SettingsSchema.cpp:693-703 七区全部 alwaysVisible —— Android 也不隐藏
  /// Update / Performance / Storage（契约 §1、§13 MUST）。
  final bool alwaysVisible;

  bool get hasCustomRenderer => customRenderer.isNotEmpty;

  /// SettingsCard.cpp:32-34：QString::number(i+1).rightJustified(2,'0')。
  String get numberText => number.toString().padLeft(2, '0');

  /// SettingsCard.cpp:42：titleEn + ' / ' + titleZh。
  String get titleText => '$titleEn / $titleZh';

  @override
  String toString() => 'SettingsSectionSpec($id, $numberText, $titleText)';
}

/// 七区表，逐字来自 SettingsSchema.cpp:693-703。
const List<SettingsSectionSpec> settingsSections = <SettingsSectionSpec>[
  SettingsSectionSpec(
      id: SettingsSectionId.provider,
      number: 1,
      order: 10,
      titleEn: 'PROVIDER ACCESS',
      titleZh: '音乐平台',
      customRenderer: SettingsCustomRenderers.providerCard,
      customHeight: 160),
  SettingsSectionSpec(
      id: SettingsSectionId.preferences,
      number: 2,
      order: 20,
      titleEn: 'TERMINAL PREFERENCES',
      titleZh: '终端偏好',
      customRenderer: '',
      customHeight: 0),
  SettingsSectionSpec(
      id: SettingsSectionId.performance,
      number: 3,
      order: 30,
      titleEn: 'PERFORMANCE',
      titleZh: '性能与诊断',
      customRenderer: SettingsCustomRenderers.performance,
      customHeight: 220),
  SettingsSectionSpec(
      id: SettingsSectionId.storage,
      number: 4,
      order: 40,
      titleEn: 'STORAGE',
      titleZh: '存储与缓存',
      customRenderer: SettingsCustomRenderers.storage,
      customHeight: 105),
  SettingsSectionSpec(
      id: SettingsSectionId.update,
      number: 5,
      order: 50,
      titleEn: 'SOFTWARE UPDATE',
      titleZh: '软件更新',
      customRenderer: SettingsCustomRenderers.update,
      customHeight: 220),
  SettingsSectionSpec(
      id: SettingsSectionId.project,
      number: 6,
      order: 60,
      titleEn: 'PROJECT',
      titleZh: '项目与开源参考',
      customRenderer: '',
      customHeight: 0),
  SettingsSectionSpec(
      id: SettingsSectionId.footer,
      number: 7,
      order: 70,
      titleEn: 'CONFIG',
      titleZh: '配置管理',
      customRenderer: SettingsCustomRenderers.defaults,
      customHeight: 84),
];

/// NativeHudSettings.cpp:39-77：按 descriptor/section 的 order 升序输出。
List<SettingsSectionSpec> orderedSettingsSections() {
  final List<SettingsSectionSpec> out = List<SettingsSectionSpec>.of(settingsSections);
  out.sort((SettingsSectionSpec a, SettingsSectionSpec b) => a.order.compareTo(b.order));
  return out;
}

/// 契约 §1 / §13 MUST：七区 visible 恒 true —— Android 也不得隐藏
/// Update / Performance / Storage。context 只作为签名占位，不参与判定。
bool settingsSectionVisible(SettingsSectionSpec section, PlatformCapabilities capabilities) =>
    section.alwaysVisible;

/// NativeHudSettings.cpp:39-77 的过滤 + 排序结果。
List<SettingsSectionSpec> visibleSettingsSections(PlatformCapabilities capabilities) {
  final List<SettingsSectionSpec> out = <SettingsSectionSpec>[];
  for (final SettingsSectionSpec section in orderedSettingsSections()) {
    if (!settingsSectionVisible(section, capabilities)) {
      continue;
    }
    out.add(section);
  }
  return out;
}

SettingsSectionSpec? settingsSectionById(SettingsSectionId id) {
  for (final SettingsSectionSpec section in settingsSections) {
    if (section.id == id) {
      return section;
    }
  }
  return null;
}

// 3. 模态/面板几何常量（契约 §5；NativeHud.h:114-139；NativeHudInput.cpp:9-36）

class SettingsModalMetrics {
  const SettingsModalMetrics._();

  /// NativeHud.h:115 SettingsViewportTop。
  static const double viewportTop = 176;

  /// NativeHud.h:116 SettingsViewportBottom。
  static const double viewportBottom = 836;

  /// NativeHudSettings.cpp:96-107 的 660 = 836 - 176。
  static const double viewportHeight = viewportBottom - viewportTop;

  /// NativeHudSettings.cpp:96：viewport.x = bounds.x() + 40。
  static const double viewportInsetX = 40;

  /// NativeHudSettings.cpp:96：viewport.width = bounds.width() - 80。
  static const double viewportInsetWidth = 80;

  /// NativeHudInput.cpp:30-33 的滚轮步长 66。
  static const double wheelStep = 66;

  /// NativeHudInput.cpp:30-33 的滚轮命中窗口横向内缩 53。
  static const double wheelHitInsetX = 53;

  /// NativeHudModal.cpp:190：类别标签 x + 53。
  static const double categoryX = 53;

  /// NativeHudModal.cpp:190：类别标签 y + 37。
  static const double categoryY = 37;

  /// NativeHudModal.cpp:190：settings 时 14pt。
  static const double categorySize = 14;

  /// NativeHudModal.cpp:190：非 settings 时 11pt。
  static const double categorySizeInactive = 11;

  /// NativeHudModal.cpp:194：标题 y + 91。
  static const double titleY = 91;

  /// NativeHudModal.cpp:194：标题 38pt demibold。
  static const double titleSize = 38;

  /// NativeHudModal.cpp:195：副标题 y + 147。
  static const double subtitleY = 147;

  /// NativeHudModal.cpp:195：settings 时 18pt。
  static const double subtitleSize = 18;

  /// NativeHudModal.cpp:195：非 settings 时 15pt。
  static const double subtitleSizeInactive = 15;

  /// NativeHudModal.cpp:191：返回按钮 y + 18。
  static const double backY = 18;

  /// NativeHudModal.cpp:191：返回按钮 167 x 54。
  static const double backWidth = 167;
  static const double backHeight = 54;

  /// NativeHudModal.cpp:191：x + usable - 220。
  static const double backInsetRight = 220;

  /// NativeHudModal.cpp:191：按钮字号 20 demibold。
  static const double backTextSize = 20;

  /// NativeHudSettings.cpp:212-224：轨道 x = x + width - 24。
  static const double railInsetRight = 24;

  /// NativeHudSettings.cpp:214：railTop = y + 176 + 30。
  static const double railTopInset = 30;

  /// NativeHudSettings.cpp:215：railHeight = viewport.height() - 60。
  static const double railBottomInset = 60;

  /// NativeHudSettings.cpp:216：轨道宽 3。
  static const double railWidth = 3;

  /// NativeHudSettings.cpp:222-223：滚动按钮 23 x 25，字号 14。
  static const double scrollButtonWidth = 23;
  static const double scrollButtonHeight = 25;
  static const double scrollButtonTextSize = 14;

  /// HudScroll.h:84 rail() 的 minThumbHeight = 30。
  static const double railMinThumbHeight = 30;

  /// NativeHudSettings.cpp:223-224：滚动按钮 x = railX - 10。
  static const double scrollButtonInsetLeft = 10;

  /// NativeHud.cpp:153：modalWidth = min(1260, width - 100)。
  static const double modalMaxWidth = 1260;
  static const double modalSideInset = 100;

  /// NativeHud.cpp:158：settings 的 modalBounds = (left, 122, modalWidth, 836)。
  static const double modalTop = 122;

  /// NativeHudModal.cpp:163：遮罩覆盖整幅 1080 高的画面。
  static const double stageHeight = 1080;

  /// NativeHudModal.cpp:171：面板高 836。
  static const double panelHeight = 836;

  /// NativeHud.cpp:113：inset = m_modalControls ? min(10, width / 8) : 0。
  static const double modalButtonInsetMax = 10;

  static double modalButtonInset(double width) {
    final double derived = width / 8;
    return derived < modalButtonInsetMax ? derived : modalButtonInsetMax;
  }

  /// NativeHud.cpp:117：文本 y = y + (height - size) / 2 - 4。
  static double modalButtonTextY(double top, double height, double size) =>
      top + (height - size) / 2 - 4;

  /// NativeHudModal.cpp:163-165：遮罩色（settings 非 search，alpha 分别 0.6 / 0.45）。
  static const SettingsRgba maskDark = SettingsRgba(17 / 255, 24 / 255, 27 / 255, 0.6);
  static const SettingsRgba maskLight = SettingsRgba(227 / 255, 224 / 255, 215 / 255, 0.45);

  /// NativeHudModal.cpp:171-172：面板底色（dark 在 Qt 侧标了 calibratedWhite）。
  static const SettingsRgba panelDark = SettingsRgba(0.15, 0.15, 0.15, 1);
  static const SettingsRgba panelLight = SettingsRgba(0.929, 0.922, 0.894, 1);

  /// NativeHud.cpp:114：模态按钮底色。
  static const SettingsRgba modalButtonDark = SettingsRgba(0.55, 0.59, 0.46, 0.13);
  static const SettingsRgba modalButtonLight = SettingsRgba(0.44, 0.49, 0.36, 0.1);

  static SettingsRgba mask(bool dark) => dark ? maskDark : maskLight;
  static SettingsRgba panel(bool dark) => dark ? panelDark : panelLight;
  static SettingsRgba modalButtonTint(bool dark) => dark ? modalButtonDark : modalButtonLight;
}

// 4. 平台候选与 provider 卡片
//    NativeHudModal.cpp:5-24（候选表）、259-291（选择器几何）
//    NativeHudSettings.cpp:242-254（actionBlock）、256-308（provider-card 自定义区）

/// 本地音乐候选 id（NativeHudModal.cpp:18）。
const String localMusicProviderId = 'local';

/// 塞壬唱片候选 id（NativeHudModal.cpp:14）。
const String sirenProviderId = 'siren';

/// 平台选择器命中 action 前缀（NativeHudModal.cpp:270）。
const String providerHitPrefix = 'provider:';

/// NativeHudModal.cpp:6-11 的 Provider 结构：id / name / label / detail。
class SettingsProviderDefinition {
  const SettingsProviderDefinition({
    required this.id,
    required this.name,
    required this.label,
    required this.detail,
  });

  final String id;
  final String name;

  /// 卡片左上角的英文短标签（NativeHudModal.cpp:274）。
  final String label;

  /// 展开态三行说明（NativeHudModal.cpp:276-280）。
  final String detail;

  /// NativeHudModal.cpp:270：action = "provider:" + provider.id，label = provider.name。
  String get hitAction => providerHitPrefix + id;
  String get hitLabel => name;

  bool get isLocal => id == localMusicProviderId;
  bool get isSiren => id == sirenProviderId;

  @override
  String toString() => 'SettingsProviderDefinition($id, $name)';
}

/// NativeHudModal.cpp:14-18 的五个候选，顺序固定不可重排。
const List<SettingsProviderDefinition> settingsProviderDefinitions = <SettingsProviderDefinition>[
  SettingsProviderDefinition(id: 'siren', name: '塞壬唱片', label: 'MONSTER SIREN', detail: '官网曲库'),
  SettingsProviderDefinition(
      id: 'netease', name: '网易云音乐', label: 'NETEASE', detail: '搜索 · 个人音乐 · 推荐 · 播放 · 歌单编辑'),
  SettingsProviderDefinition(
      id: 'qq', name: 'QQ 音乐', label: 'QQ MUSIC', detail: '全类搜索 · 每日推荐 · 个人音乐 · 歌单编辑'),
  SettingsProviderDefinition(
      id: 'kugou', name: '酷狗音乐', label: 'KUGOU', detail: '标准版 / 概念版 · 个人歌单 · 推荐与榜单 · 播放'),
  SettingsProviderDefinition(
      id: 'local', name: '本地音乐', label: 'LOCAL', detail: '文件夹管理 · 导入与索引 · 本地检索 · 播放'),
];

/// NativeHudModal.cpp:20-23：非 LocalMusic 平台移除 local（Android / iOS 恒 4 项）。
List<SettingsProviderDefinition> providerChoices(PlatformCapabilities capabilities) {
  final List<SettingsProviderDefinition> out =
      List<SettingsProviderDefinition>.of(settingsProviderDefinitions);
  if (!capabilities.localMusic && out.isNotEmpty && out.last.id == localMusicProviderId) {
    out.removeLast();
  }
  return out;
}

/// provider 卡片几何（NativeHudSettings.cpp:257-306 逐字）。
class ProviderCardMetrics {
  const ProviderCardMetrics._();

  /// :257 card = QRectF(body.left(), body.top() + 4, body.width(), 80)。
  static const double cardInsetTop = 4;
  static const double cardHeight = 80;

  /// :259 左侧金条宽 3。
  static const double accentWidth = 3;

  /// :260 mark = QRectF(card.left() + 14, card.top() + 17, 46, 46)。
  static const double markSize = 46;
  static const double markInsetLeft = 14;
  static const double markInsetTop = 17;

  /// :264 scale(mark.width() / 24, mark.height() / 24)。
  static const double markGlyphExtent = 24;

  /// :268-270 文本列 x = card.left() + 74。
  static const double textInsetLeft = 74;
  static const double currentLabelInsetTop = 10;
  static const double providerNameInsetTop = 24;
  static const double providerCodeInsetTop = 52;
  static const double currentLabelSize = 10;
  static const double providerNameSize = 20;
  static const double providerCodeSize = 10;
  static const double currentLabelTracking = 0.08;
  static const double providerNameTracking = -0.02;
  static const double providerCodeTracking = 0.07;

  /// :268 当前平台栏文案。
  static const String currentLabelText = 'CURRENT PROVIDER / 当前平台';

  /// :271 switchRect = QRectF(card.right() - 126, card.top() + 23, 110, 34)。
  static const double switchInsetRight = 126;
  static const double switchInsetTop = 23;
  static const double switchWidth = 110;
  static const double switchHeight = 34;

  /// :272 绘制文案与命中 label 是两个不同字符串，不得合并。
  static const String switchPaintLabel = '切换平台 ▾';
  static const String switchAction = 'provider';
  static const String switchHitLabel = '切换平台';

  /// :289 account = QRectF(body.left(), body.top() + 98, 320, 46)。
  static const double accountInsetTop = 98;
  static const double accountWidth = 320;
  static const double accountHeight = 46;

  /// :291 无 action 分支的纯文本位置与字号。
  static const double accountTextInsetLeft = 2;
  static const double accountTextInsetTop = 15;
  static const double accountTextSize = 15;

  /// :305-306 右侧注释 x = account.right() + 16，y = body.top() + 114，12pt。
  static const double noteInsetLeft = 16;
  static const double noteInsetTop = 114;
  static const double noteSize = 12;

  /// :305 注释可用宽度 = body.right() - account.right() - 20。
  static const double noteInsetRight = 20;

  /// :242-254 actionBlock：填充 soft、描边 line、文本 left+12 / top+15（14pt）、命中整块。
  static const double actionTextInsetLeft = 12;
  static const double actionTextInsetTop = 15;
  static const double actionTextSize = 14;

  /// :247 fit 的宽度余量 rect.width() - 26。
  static const double actionFitInset = 26;
}

/// 选择器几何（NativeHudModal.cpp:259-291 逐字）。
class ProviderChooserMetrics {
  const ProviderChooserMetrics._();

  /// :260 constexpr double gap = 12。
  static const double gap = 12;

  /// :266 const auto height = expanded ? 190 : 66。
  static const double expandedHeight = 190;
  static const double collapsedHeight = 66;

  /// :261 cardWidth = (width - gap * (count - 1)) / count。
  static double cardWidth(double width, int count) => (width - gap * (count - 1)) / count;

  /// :262-264 left = x + index * (cardWidth + gap)。
  static double cardLeft(double x, double width, int count, int index) =>
      x + index * (cardWidth(width, count) + gap);

  /// :274-280 卡片内文本列。
  static const double textInsetLeft = 16;
  static const double labelInsetTop = 10;
  static const double nameInsetTop = 29;
  static const double detailInsetTop = 75;
  static const double detailRowStep = 21;
  static const int detailMaxRows = 3;
  static const double noteInsetTop = 150;
  static const double labelSize = 10;
  static const double nameSizeExpanded = 22;
  static const double nameSizeCollapsed = 17;
  static const double detailSize = 14;
  static const double noteSize = 12;

  /// :274 选中后缀。
  static const String selectedSuffix = ' / ACTIVE';

  /// :271-272 选中项左侧金条宽 3。
  static const double accentWidth = 3;

  /// :276 / :288 fit 的宽度余量 cardWidth - 32。
  static const double detailFitInset = 32;
  static const double noteFitInset = 32;
}

/// :267-268 卡片底色。
SettingsRgba providerChoiceTint({required bool dark, required bool selected}) => dark
    ? SettingsRgba(0.55, 0.59, 0.46, selected ? 0.3 : 0.12)
    : SettingsRgba(0.44, 0.49, 0.36, selected ? 0.23 : 0.09);

/// :271-272 选中金条颜色。
SettingsRgba providerChoiceAccent({required bool dark}) =>
    dark ? const SettingsRgba(0.7, 0.75, 0.53, 1) : const SettingsRgba(0.44, 0.49, 0.36, 1);

/// 一张候选卡片的几何与选中态。
class ProviderChoicePlacement {
  const ProviderChoicePlacement({
    required this.definition,
    required this.index,
    required this.bounds,
    required this.selected,
  });

  final SettingsProviderDefinition definition;
  final int index;
  final Rect bounds;
  final bool selected;

  String get labelText =>
      definition.label + (selected ? ProviderChooserMetrics.selectedSuffix : '');
  double get nameSize => bounds.height == ProviderChooserMetrics.expandedHeight
      ? ProviderChooserMetrics.nameSizeExpanded
      : ProviderChooserMetrics.nameSizeCollapsed;

  @override
  String toString() => 'ProviderChoicePlacement(${definition.id}, $bounds)';
}

/// :262-264 逐卡布局；x 已是 platformChoices 的左缘（platformPanel 传 x + 53）。
List<ProviderChoicePlacement> placeProviderChoices({
  required double left,
  required double top,
  required double width,
  required List<SettingsProviderDefinition> providers,
  required String selectedId,
  required bool expanded,
}) {
  final int count = providers.length;
  if (count <= 0) {
    return const <ProviderChoicePlacement>[];
  }
  final double cardWidth = ProviderChooserMetrics.cardWidth(width, count);
  final double height = expanded
      ? ProviderChooserMetrics.expandedHeight
      : ProviderChooserMetrics.collapsedHeight;
  final List<ProviderChoicePlacement> out = <ProviderChoicePlacement>[];
  for (int index = 0; index < count; index++) {
    final SettingsProviderDefinition definition = providers[index];
    out.add(ProviderChoicePlacement(
      definition: definition,
      index: index,
      bounds: Rect.fromLTWH(ProviderChooserMetrics.cardLeft(left, width, count, index), top,
          cardWidth, height),
      selected: definition.id == selectedId,
    ));
  }
  return out;
}

/// 卡片绘制所需的平台/账号状态（对应 Qt 的 MusicLibrary + Host::hasCredential）。
class SettingsProviderState {
  const SettingsProviderState({
    required this.providerId,
    required this.providerName,
    this.uid = '',
    this.nickname = '',
    this.vipLevel = '',
  });

  /// MusicLibrary::provider。
  final String providerId;

  /// MusicLibrary::providerName()。
  final String providerName;

  /// MusicLibrary::uid。
  final String uid;

  /// MusicLibrary::nickname。
  final String nickname;

  /// MusicLibrary::vipLevel。
  final String vipLevel;

  bool get isLocal => providerId == localMusicProviderId;
  bool get isSiren => providerId == sirenProviderId;

  /// NativeHudSettings.cpp:270 的 provider.toUpper()。
  String get providerCode => providerId.toUpperCase();

  @override
  String toString() => 'SettingsProviderState($providerId, uid: $uid)';
}

/// 账号行：label + action（action 为空表示纯文本行）。
class ProviderAccountRow {
  const ProviderAccountRow({required this.label, required this.action});

  final String label;
  final String action;

  bool get isText => action.isEmpty;

  @override
  String toString() => 'ProviderAccountRow($label, $action)';
}

/// NativeHudSettings.cpp:276-288 的四分支。
ProviderAccountRow providerAccountRow(SettingsProviderState state) {
  if (state.isLocal) {
    // :276-278
    return const ProviderAccountRow(label: '文件夹管理 / 导入与索引', action: 'discover');
  }
  if (state.isSiren) {
    // :279-281 塞壬唱片没有账号登录入口，纯文本。
    return const ProviderAccountRow(label: '塞壬唱片', action: '');
  }
  if (state.uid.isEmpty) {
    // :282-284
    return ProviderAccountRow(label: '登录 / ${state.providerName}', action: 'music:login');
  }
  // :285-288
  return ProviderAccountRow(label: '退出登录 / ${state.nickname}', action: 'music:logout');
}

/// NativeHudSettings.cpp:296-299 的会员态表。
const Map<String, String> providerMembershipNotes = <String, String>{
  'free': '免费账号',
  'green': '绿钻会员',
  'super': '超级会员',
  'unknown': '会员状态未知',
};

/// NativeHudSettings.cpp:300-304 的右侧注释。
String providerAccountNote(SettingsProviderState state) {
  if (state.isSiren) {
    return '官网曲库 / 无需登录';
  }
  if (state.providerId == 'qq' && state.uid.isNotEmpty) {
    return providerMembershipNotes[state.vipLevel] ?? '会员状态未知';
  }
  return '各平台账号独立保存';
}

// 5. 卡片布局（SettingsCard.cpp:239-292 逐条；复用 A1 的 placeSettingsRow / placeProjectLink）

/// 一个分区的模型：分区定义 + 该区普通行（自定义区为空表）。
class SettingsSectionModel {
  const SettingsSectionModel({required this.spec, this.rows = const <SettingsRowSpec>[]});

  final SettingsSectionSpec spec;
  final List<SettingsRowSpec> rows;

  @override
  String toString() => 'SettingsSectionModel(${spec.id}, rows: ${rows.length})';
}

/// 一个分区的布局（对应 SettingsCard::SectionLayout）。
class SettingsSectionLayout {
  const SettingsSectionLayout({
    required this.section,
    required this.header,
    required this.body,
    required this.rows,
    required this.height,
  });

  final SettingsSectionSpec section;
  final Rect header;
  final Rect body;
  final List<SettingsRowLayout> rows;
  final double height;

  /// SettingsCard.cpp:296-302：paint() 把 header / body / 每行整体上移 scroll。
  SettingsSectionLayout translated(double dy) => SettingsSectionLayout(
        section: section,
        header: header.translate(0, dy),
        body: body.translate(0, dy),
        rows: rows.map((SettingsRowLayout row) => row.translated(dy)).toList(growable: false),
        height: height,
      );

  @override
  String toString() => 'SettingsSectionLayout(${section.id}, $header)';
}

/// 整卡布局（对应 SettingsCard::Layout）。
class SettingsCardLayout {
  const SettingsCardLayout({
    required this.viewport,
    required this.sections,
    required this.contentHeight,
    required this.maximumScroll,
  });

  final Rect viewport;
  final List<SettingsSectionLayout> sections;
  final double contentHeight;
  final double maximumScroll;

  double get viewportHeight => viewport.height;

  @override
  String toString() => 'SettingsCardLayout(contentHeight: $contentHeight, maximumScroll: $maximumScroll)';
}

/// NativeHudSettings.cpp:66：row.expanded = expandedId == descriptor.id && row.enabled。
bool settingsRowExpanded({required SettingsRowSpec row, required String expandedId}) =>
    expandedId == row.id && row.enabled;

/// SettingsCard.cpp:239-292 的 layout() 逐条复刻。
SettingsCardLayout layoutSettingsCard({
  required Rect viewport,
  required List<SettingsSectionModel> model,
}) {
  final double left = viewport.left + SettingsRowMetrics.contentInset;
  final double width = viewport.width - SettingsRowMetrics.contentInset * 2;
  double cursor = viewport.top;
  final List<SettingsSectionLayout> sections = <SettingsSectionLayout>[];
  for (final SettingsSectionModel section in model) {
    final SettingsSectionSpec spec = section.spec;
    // :248 header = QRectF(viewport.left(), cursor, viewport.width(), HeaderHeight)。
    final Rect header =
        Rect.fromLTWH(viewport.left, cursor, viewport.width, SettingsRowMetrics.headerHeight);
    cursor += SettingsRowMetrics.headerHeight;
    final List<SettingsRowLayout> rows = <SettingsRowLayout>[];
    final Rect body;
    final double height;
    if (spec.hasCustomRenderer) {
      // :250-254 自定义区。
      final double bodyHeight = math.max(0.0, spec.customHeight);
      body = Rect.fromLTWH(left, cursor, width, bodyHeight);
      height = SettingsRowMetrics.headerHeight + bodyHeight;
      cursor += bodyHeight + SettingsRowMetrics.sectionGap;
    } else if (spec.id == SettingsSectionId.project) {
      // :255-267 Project 两列网格。
      for (int index = 0; index < section.rows.length; index++) {
        rows.add(placeProjectLink(
            row: section.rows[index], index: index, left: left, width: width, cursor: cursor));
      }
      final double bodyHeight = SettingsRowMetrics.linkBodyHeight(section.rows.length);
      body = Rect.fromLTWH(left, cursor, width, bodyHeight);
      height = SettingsRowMetrics.headerHeight + bodyHeight;
      cursor += bodyHeight + SettingsRowMetrics.sectionGap;
    } else {
      // :268-286 普通行分区。
      final double bodyTop = cursor;
      for (final SettingsRowSpec row in section.rows) {
        final SettingsRowPlacement placement =
            placeSettingsRow(row: row, left: left, width: width, cursor: cursor);
        rows.add(placement.layout);
        cursor = placement.nextCursor;
      }
      body = Rect.fromLTWH(left, bodyTop, width, cursor - bodyTop);
      height = SettingsRowMetrics.headerHeight + (cursor - bodyTop);
      cursor += SettingsRowMetrics.sectionGap;
    }
    sections.add(SettingsSectionLayout(
        section: spec, header: header, body: body, rows: rows, height: height));
  }
  // :289-290。
  final double contentHeight = cursor - viewport.top + SettingsRowMetrics.bottomPad;
  return SettingsCardLayout(
    viewport: viewport,
    sections: sections,
    contentHeight: contentHeight,
    maximumScroll: SettingsRowMetrics.maximumScroll(contentHeight, viewport.height),
  );
}

// 6. 面板视口 / 滚动轨道 / 滚轮
//    NativeHudSettings.cpp:164-165, 205-224；HudScroll.h:13-26, 50-86；NativeHudInput.cpp:29-33

class SettingsPanelGeometry {
  const SettingsPanelGeometry._();

  /// NativeHudSettings.cpp:164-165：viewport = (x + 40, y + 176, width - 80, 660)。
  static Rect viewport({required double x, required double y, required double width}) =>
      Rect.fromLTWH(x + SettingsModalMetrics.viewportInsetX, y + SettingsModalMetrics.viewportTop,
          width - SettingsModalMetrics.viewportInsetWidth, SettingsModalMetrics.viewportHeight);

  /// NativeHudModal.cpp:199-200：返回按钮 (x + usable - 220, y + 18, 167, 54)，命中 close-modal。
  static Rect backButton({required double x, required double y, required double usable}) =>
      Rect.fromLTWH(x + usable - SettingsModalMetrics.backInsetRight, y + SettingsModalMetrics.backY,
          SettingsModalMetrics.backWidth, SettingsModalMetrics.backHeight);

  /// NativeHudSettings.cpp:212-215：track = (x + width - 24, y + 176 + 30, 3, 660 - 60)。
  static Rect scrollTrack({required double x, required double y, required double width}) =>
      Rect.fromLTWH(
          x + width - SettingsModalMetrics.railInsetRight,
          y + SettingsModalMetrics.viewportTop + SettingsModalMetrics.railTopInset,
          SettingsModalMetrics.railWidth,
          SettingsModalMetrics.viewportHeight - SettingsModalMetrics.railBottomInset);

  /// NativeHudSettings.cpp:223：上滚按钮 (railX - 10, y + 176, 23, 25)，命中 settings:scroll-up。
  static Rect scrollUpButton({required Rect track, required double y}) => Rect.fromLTWH(
      track.left - SettingsModalMetrics.scrollButtonInsetLeft,
      y + SettingsModalMetrics.viewportTop,
      SettingsModalMetrics.scrollButtonWidth,
      SettingsModalMetrics.scrollButtonHeight);

  /// NativeHudSettings.cpp:224：下滚按钮 (railX - 10, y + 836 - 25, 23, 25)，命中 settings:scroll-down。
  static Rect scrollDownButton({required Rect track, required double y}) => Rect.fromLTWH(
      track.left - SettingsModalMetrics.scrollButtonInsetLeft,
      y + SettingsModalMetrics.viewportBottom - SettingsModalMetrics.scrollButtonHeight,
      SettingsModalMetrics.scrollButtonWidth,
      SettingsModalMetrics.scrollButtonHeight);

  static const String scrollUpAction = 'settings:scroll-up';
  static const String scrollDownAction = 'settings:scroll-down';
  static const String scrollUpGlyph = '↑';
  static const String scrollDownGlyph = '↓';
}

/// HudScroll.h:43-47 的 Rail。
class SettingsScrollRail {
  const SettingsScrollRail({required this.visible, required this.track, required this.thumb});

  final bool visible;
  final Rect track;
  final Rect thumb;

  @override
  String toString() => 'SettingsScrollRail(visible: $visible, $thumb)';
}

/// HudScroll.h:50-64 rail() 逐字：无滚动余量时不返回 thumb。
SettingsScrollRail settingsScrollRail({
  required Rect track,
  required double contentHeight,
  required double viewportHeight,
  required double offset,
  double minThumbHeight = SettingsModalMetrics.railMinThumbHeight,
}) {
  final double range = SettingsRowMetrics.maximumScroll(contentHeight, viewportHeight);
  if (range <= 0 || track.height <= 0) {
    return SettingsScrollRail(visible: false, track: track, thumb: Rect.zero);
  }
  final double lower = math.min(minThumbHeight, track.height);
  final double rawThumb = track.height * viewportHeight / contentHeight;
  final double thumbHeight = math.max(lower, math.min(rawThumb, track.height));
  final double normalized = (offset / range).clamp(0.0, 1.0).toDouble();
  final double thumbTop = track.top + normalized * (track.height - thumbHeight);
  return SettingsScrollRail(
      visible: true,
      track: track,
      thumb: Rect.fromLTWH(track.left, thumbTop, track.width, thumbHeight));
}

/// HudScroll.h:22-26 applyWheel：distance 优先，否则 steps * stepPixels，最后 clamp。
double settingsWheelScroll({
  required double offset,
  required double contentHeight,
  required double viewportHeight,
  required int steps,
  double? distance,
  double stepPixels = SettingsModalMetrics.wheelStep,
}) {
  final double movement = (distance != null && distance != 0) ? distance : steps * stepPixels;
  return SettingsRowMetrics.clampScroll(offset + movement, contentHeight, viewportHeight);
}

/// NativeHudInput.cpp:29-33 的滚轮命中窗口（已扣除位移 motionOffset）。
bool settingsWheelHits({
  required Rect bounds,
  required double pointerX,
  required double pointerY,
  double motionOffset = 0,
  bool closing = false,
}) {
  if (closing) {
    return false;
  }
  final double localY = pointerY - motionOffset;
  return pointerX >= bounds.left + SettingsModalMetrics.wheelHitInsetX &&
      pointerX <= bounds.right - SettingsModalMetrics.wheelHitInsetX &&
      localY >= bounds.top + SettingsModalMetrics.viewportTop &&
      localY <= bounds.top + SettingsModalMetrics.viewportBottom;
}

// 7. 绘制：自定义区 / 表头 / 整卡 / 面板 / 模态框架 / 编辑浮层 / 性能面板规格
//    NativeHudSettings.cpp:227-380；SettingsCard.cpp:36-45,294-327；
//    NativeHudModal.cpp:188-202；Overlay.qml:563-602；PerformancePanel.qml:1-150

/// NativeHudSettings.cpp:236-241 与 :195-200 的 stroke 不是"描边框线"，而是 4 条 1px 填充：
/// 上 / 下 / 左 / 右，其中下边用 bottom-1、右边用 right-1 内缩。
/// 这里就地复刻 Qt 原式（A1 的 SettingsRowMetrics.strokeFillRects 未逐行核对，不复用其行为）。
void paintSettingsStrokeEdges(Rect rect, SettingsRgba color, SettingsCanvas canvas) {
  canvas.fill(rect.left, rect.top, rect.width, 1, color);
  canvas.fill(rect.left, rect.bottom - 1, rect.width, 1, color);
  canvas.fill(rect.left, rect.top, 1, rect.height, color);
  canvas.fill(rect.right - 1, rect.top, 1, rect.height, color);
}

/// NativeHudSettings.cpp:242-254 的 actionBlock：填充 soft、四边 line、文本、整块命中。
/// label 是绘制文案，hitLabel 是命中 label —— provider 切换按钮两者不同，不得合并。
void paintSettingsActionBlock({
  required Rect rect,
  required String label,
  required String action,
  required String hitLabel,
  required SettingsCanvas canvas,
  required SettingsPalette palette,
  SettingsTextFit fit = identitySettingsTextFit,
  bool centeredLabel = false,
}) {
  canvas.fill(rect.left, rect.top, rect.width, rect.height, palette.soft);
  paintSettingsStrokeEdges(rect, palette.line, canvas);
  // :247 固定 14pt（provider 卡片与各行 actionBlock 共用同一常量）。
  final String shown = fit(label, ProviderCardMetrics.actionTextSize,
      rect.width - ProviderCardMetrics.actionFitInset, SettingsFontWeight.regular);
  if (centeredLabel) {
    // :249 centeredText(shown, rect.center().x, rect.center().y, 14, "regular", true)
    canvas.centered(shown, rect.center.dx, rect.center.dy, ProviderCardMetrics.actionTextSize,
        SettingsFontWeight.regular, true);
  } else {
    // :251 text(shown, rect.left() + 12, rect.top() + 15, 14, "regular", 0, baseInk)
    canvas.text(shown, rect.left + ProviderCardMetrics.actionTextInsetLeft,
        rect.top + ProviderCardMetrics.actionTextInsetTop, ProviderCardMetrics.actionTextSize,
        SettingsFontWeight.regular, 0, palette.ink);
  }
  // :253 hit(rect.left(), rect.top(), rect.width(), rect.height(), action, hitLabel)
  canvas.hit(rect.left, rect.top, rect.width, rect.height, action, hitLabel);
}

/// NativeHudSettings.cpp:15-16 / :17-18 的两条 24×24 单色 SVG path，逐字保留。
/// :261-267 的渲染序列：save / translate(mark.left, mark.top) / scale(mark.width/24) /
/// fill-path(AppleMusicIcon, ink) / fill-path(AppleMusicNote, panel) / restore —— 全平台单色。
class SettingsAppleMusicMark {
  const SettingsAppleMusicMark._();

  /// SettingsCanvas.custom 的 renderer 名（本文件自定，平台层据此绘制标记）。
  static const String renderer = 'apple-music-mark';

  /// :15-16 constexpr auto AppleMusicIcon。
  static const String iconPath =
      'M 23.994 6.124 C 24.002 5.387 23.921 4.652 23.754 3.934 C 23.437 2.624 22.692 1.624 21.574 0.891 C 21.004 0.525 20.365 0.278 19.697 0.165 C 19.18 0.076 18.657 0.026 18.133 0.015 C 18.093 0.012 18.05 0.005 18.009 0.002 L 5.986 0.002 C 5.834 0.012 5.683 0.019 5.531 0.028 C 4.784 0.071 4.041 0.151 3.338 0.428 C 2.002 0.958 1.038 1.88 0.473 3.208 C 0.281 3.656 0.181 4.133 0.11 4.616 C 0.054 5.008 0.022 5.401 0.01 5.796 C 0.01 5.828 0.003 5.858 0 5.889 L 0 18.112 C 0.01 18.252 0.017 18.395 0.027 18.536 C 0.077 19.351 0.181 20.16 0.524 20.909 C 1.174 22.329 2.262 23.262 3.758 23.71 C 4.178 23.837 4.614 23.897 5.051 23.938 C 5.606 23.991 6.161 23.998 6.718 23.998 L 17.748 23.998 C 18.273 23.998 18.797 23.964 19.318 23.898 C 20.14 23.792 20.914 23.548 21.613 23.088 C 22.442 22.552 23.096 21.785 23.493 20.881 C 23.679 20.461 23.786 20.011 23.863 19.557 C 23.976 18.882 24.001 18.199 24 17.517 C 23.998 13.717 24 9.922 23.997 6.124 Z';

  /// :17-18 constexpr auto AppleMusicNote。
  static const String notePath =
      'M 17.571 10.114 L 17.571 15.826 C 17.571 16.243 17.513 16.653 17.327 17.032 C 17.037 17.622 16.567 17.994 15.939 18.172 C 15.589 18.272 15.233 18.329 14.869 18.345 C 13.919 18.39 13.096 17.745 12.926 16.809 C 12.779 15.978 13.204 15.152 13.964 14.787 C 14.287 14.627 14.634 14.537 14.982 14.463 C 15.36 14.381 15.74 14.31 16.116 14.223 C 16.39 14.16 16.573 13.993 16.626 13.707 C 16.64 13.644 16.646 13.579 16.646 13.514 C 16.646 11.699 16.646 9.884 16.644 8.071 C 16.643 8.008 16.635 7.946 16.618 7.886 C 16.578 7.736 16.468 7.643 16.314 7.652 C 16.154 7.662 15.996 7.687 15.839 7.718 C 15.079 7.868 14.319 8.021 13.559 8.174 L 11.234 8.644 L 9.86 8.922 C 9.844 8.925 9.828 8.932 9.812 8.935 C 9.535 9.012 9.435 9.138 9.422 9.425 C 9.42 9.467 9.422 9.511 9.422 9.555 C 9.42 12.157 9.422 14.759 9.419 17.36 C 9.419 17.78 9.372 18.196 9.204 18.587 C 8.926 19.227 8.434 19.627 7.77 19.82 C 7.42 19.92 7.06 19.98 6.695 19.992 C 5.735 20.028 4.94 19.392 4.775 18.448 C 4.635 17.636 5.005 16.763 5.929 16.373 C 6.286 16.223 6.659 16.141 7.037 16.063 C 7.324 16.003 7.612 15.947 7.897 15.886 C 8.28 15.803 8.48 15.563 8.497 15.172 L 8.497 15.022 C 8.497 12.062 8.497 9.1 8.499 6.14 C 8.499 6.017 8.512 5.89 8.541 5.77 C 8.611 5.485 8.814 5.322 9.087 5.252 C 9.342 5.186 9.602 5.14 9.861 5.087 C 10.594 4.937 11.327 4.791 12.061 4.643 L 14.331 4.183 C 15.001 4.049 15.671 3.913 16.341 3.78 C 16.561 3.737 16.783 3.692 17.004 3.674 C 17.314 3.649 17.527 3.844 17.558 4.156 C 17.566 4.229 17.57 4.304 17.57 4.379 C 17.572 6.289 17.572 8.201 17.57 10.111 Z';

  /// 图层 0 用 ink（baseInk），图层 1 用 panel（:265-266）。
  static const String iconPaint = 'ink';
  static const String notePaint = 'panel';
  static const String iconLayer = 'icon';
  static const String noteLayer = 'note';
  static const int layerCount = 2;

  static String layerName(int layer) => layer == 0 ? iconLayer : noteLayer;
  static String layerPath(int layer) => layer == 0 ? iconPath : notePath;
  static String layerPaintRole(int layer) => layer == 0 ? iconPaint : notePaint;
}

/// :260 card = QRectF(body.left(), body.top() + 4, body.width(), 80)。
Rect settingsProviderCardRect(Rect body) => Rect.fromLTWH(body.left,
    body.top + ProviderCardMetrics.cardInsetTop, body.width, ProviderCardMetrics.cardHeight);

/// :260 mark = QRectF(card.left() + 14, card.top() + 17, 46, 46)。
Rect settingsProviderMarkRect(Rect body) {
  final Rect card = settingsProviderCardRect(body);
  return Rect.fromLTWH(card.left + ProviderCardMetrics.markInsetLeft,
      card.top + ProviderCardMetrics.markInsetTop, ProviderCardMetrics.markSize,
      ProviderCardMetrics.markSize);
}

/// :289 account = QRectF(body.left(), body.top() + 98, 320, 46)。
Rect settingsProviderAccountRect(Rect body) => Rect.fromLTWH(body.left,
    body.top + ProviderCardMetrics.accountInsetTop, ProviderCardMetrics.accountWidth,
    ProviderCardMetrics.accountHeight);

/// :271 switchRect = QRectF(card.right() - 126, card.top() + 23, 110, 34)。
Rect settingsProviderSwitchRect(Rect body) {
  final Rect card = settingsProviderCardRect(body);
  return Rect.fromLTWH(card.right - ProviderCardMetrics.switchInsetRight,
      card.top + ProviderCardMetrics.switchInsetTop, ProviderCardMetrics.switchWidth,
      ProviderCardMetrics.switchHeight);
}

/// :261-267：SettingsCanvas 没有 path 图元，标记用 custom op 承载（renderer + mark 矩形）。
void paintSettingsAppleMusicMark({required Rect mark, required SettingsCanvas canvas}) {
  canvas.custom(SettingsAppleMusicMark.renderer, mark, 0);
}

/// NativeHudSettings.cpp:256-308 的 provider-card 自定义区。
void paintProviderCardSection({
  required Rect body,
  required SettingsProviderState state,
  required SettingsCanvas canvas,
  required SettingsPalette palette,
  SettingsTextFit fit = identitySettingsTextFit,
}) {
  final Rect card = settingsProviderCardRect(body);
  // :258 fill(card, soft)
  canvas.fill(card.left, card.top, card.width, card.height, palette.soft);
  // :259 fill(card.left(), card.top(), 3, card.height(), gold) —— 左侧金条
  canvas.fill(card.left, card.top, ProviderCardMetrics.accentWidth, card.height, palette.gold);
  // :260-267 Apple Music 标记
  paintSettingsAppleMusicMark(mark: settingsProviderMarkRect(body), canvas: canvas);
  // :268 "CURRENT PROVIDER / 当前平台" 10pt muted，tracking 0.08
  canvas.text(ProviderCardMetrics.currentLabelText,
      card.left + ProviderCardMetrics.textInsetLeft,
      card.top + ProviderCardMetrics.currentLabelInsetTop, ProviderCardMetrics.currentLabelSize,
      SettingsFontWeight.regular, ProviderCardMetrics.currentLabelTracking, palette.muted);
  // :269 providerName 20pt demibold，tracking -0.02
  canvas.text(state.providerName, card.left + ProviderCardMetrics.textInsetLeft,
      card.top + ProviderCardMetrics.providerNameInsetTop, ProviderCardMetrics.providerNameSize,
      SettingsFontWeight.demibold, ProviderCardMetrics.providerNameTracking, palette.ink);
  // :270 provider.toUpper() 10pt muted，tracking 0.07
  canvas.text(state.providerCode, card.left + ProviderCardMetrics.textInsetLeft,
      card.top + ProviderCardMetrics.providerCodeInsetTop, ProviderCardMetrics.providerCodeSize,
      SettingsFontWeight.regular, ProviderCardMetrics.providerCodeTracking, palette.muted);
  // :271-272 切换按钮：绘制 "切换平台 ▾"，命中 label "切换平台"，action "provider"
  paintSettingsActionBlock(
    rect: settingsProviderSwitchRect(body),
    label: ProviderCardMetrics.switchPaintLabel,
    action: ProviderCardMetrics.switchAction,
    hitLabel: ProviderCardMetrics.switchHitLabel,
    canvas: canvas,
    palette: palette,
    fit: fit,
    centeredLabel: true,
  );
  // :274-295 账号行四分支
  final ProviderAccountRow account = providerAccountRow(state);
  final Rect accountRect = settingsProviderAccountRect(body);
  if (account.isText) {
    // :291 text(fit(label, 15, account.width(), "regular"), account.left() + 2, account.top() + 15, 15)
    canvas.text(
        fit(account.label, ProviderCardMetrics.accountTextSize, accountRect.width,
            SettingsFontWeight.regular),
        accountRect.left + ProviderCardMetrics.accountTextInsetLeft,
        accountRect.top + ProviderCardMetrics.accountTextInsetTop,
        ProviderCardMetrics.accountTextSize, SettingsFontWeight.regular, 0, palette.ink);
  } else {
    paintSettingsActionBlock(
      rect: accountRect,
      label: account.label,
      action: account.action,
      hitLabel: account.label,
      canvas: canvas,
      palette: palette,
      fit: fit,
    );
  }
  // :300-306 右侧注释 x = account.right() + 16，y = body.top() + 114，12pt
  final double noteWidth =
      body.right - accountRect.right - ProviderCardMetrics.noteInsetRight;
  canvas.text(
      fit(providerAccountNote(state), ProviderCardMetrics.noteSize, noteWidth,
          SettingsFontWeight.regular),
      accountRect.right + ProviderCardMetrics.noteInsetLeft,
      body.top + ProviderCardMetrics.noteInsetTop, ProviderCardMetrics.noteSize,
      SettingsFontWeight.regular, 0, palette.muted);
}

/// NativeHudSettings.cpp:310-330 的 performance 自定义区几何。
class SettingsPerformanceSectionMetrics {
  const SettingsPerformanceSectionMetrics._();

  /// :320 row(4, ...) 与 :324 row(102, ...)。
  static const double firstRowTop = 4;
  static const double secondRowTop = 102;

  /// :311 control = QRectF(body.right() - 300, body.top() + top + 8, 300, 48)。
  static const double controlInsetTop = 8;
  static const double controlHeight = 48;

  /// :313-314 英文小标题 11pt muted tracking 0.08。
  static const double titleInsetTop = 10;
  static const double titleSize = 11;
  static const double titleTracking = 0.08;

  /// :315 中文标题 17pt demibold tracking -0.01。
  static const double subtitleInsetTop = 25;
  static const double subtitleSize = 17;
  static const double subtitleTracking = -0.01;

  /// :317 fill(body.left(), body.top() + top + 62, body.width(), 1, line)。
  static const double ruleInsetTop = 62;

  /// :322-323 / :327-328 帮助文本 13pt。
  static const double firstHelpInsetTop = 78;
  static const double secondHelpInsetTop = 176;
  static const double helpSize = 13;
}

/// NativeHudSettings.cpp:320-328 的逐字文案。
class SettingsPerformanceContent {
  const SettingsPerformanceContent._();

  // 性能面板停用：第一行 PERFORMANCE 的文案 / action / 帮助均不再提供。

  static const String secondTitleEn = 'DISC ROTATION';
  static const String secondTitleZh = '唱片旋转';
  static const String secondAction = 'disc-rotation';
  static const String secondHitLabel = '唱片旋转';
  static const String secondLabelOn = '开启 / 点击关闭';
  static const String secondLabelOff = '关闭 / 点击了解风险';
  static const String secondHelp = '默认关闭；开启会增加持续渲染、耗电和发热。';

  // 性能面板停用：PERFORMANCE 行的固定 label 不再声明。
}

/// NativeHudSettings.cpp:310-330。
void paintPerformanceSection({
  required Rect body,
  required bool discRotation,
  required SettingsCanvas canvas,
  required SettingsPalette palette,
  SettingsTextFit fit = identitySettingsTextFit,
}) {
  void row(double top, String titleEn, String titleZh, String label, String action,
      String hitLabel) {
    final Rect control = Rect.fromLTWH(body.right - SettingsRowMetrics.controlWidth,
        body.top + top + SettingsPerformanceSectionMetrics.controlInsetTop,
        SettingsRowMetrics.controlWidth, SettingsPerformanceSectionMetrics.controlHeight);
    canvas.text(titleEn, body.left, body.top + top + SettingsPerformanceSectionMetrics.titleInsetTop,
        SettingsPerformanceSectionMetrics.titleSize, SettingsFontWeight.regular,
        SettingsPerformanceSectionMetrics.titleTracking, palette.muted);
    canvas.text(titleZh, body.left,
        body.top + top + SettingsPerformanceSectionMetrics.subtitleInsetTop,
        SettingsPerformanceSectionMetrics.subtitleSize, SettingsFontWeight.demibold,
        SettingsPerformanceSectionMetrics.subtitleTracking, palette.ink);
    paintSettingsActionBlock(
      rect: control,
      label: label,
      action: action,
      hitLabel: hitLabel,
      canvas: canvas,
      palette: palette,
      fit: fit,
    );
    canvas.fill(body.left, body.top + top + SettingsPerformanceSectionMetrics.ruleInsetTop,
        body.width, 1, palette.line);
  }

  // 「注释掉所有性能面板相关的代码，我他妈就没让你做这个」——第一行
  // （PERFORMANCE / 性能面板 → performance:toggle）是性能面板的显示入口，注释掉；
  // 第二行（DISC ROTATION / 唱片旋转）是用户指定设置项，保留。
  // row(SettingsPerformanceSectionMetrics.firstRowTop, SettingsPerformanceContent.firstTitleEn,
  //     SettingsPerformanceContent.firstTitleZh, SettingsPerformanceContent.firstLabel,
  //     SettingsPerformanceContent.firstAction, SettingsPerformanceContent.firstHitLabel);
  // canvas.text(SettingsPerformanceContent.firstHelp, body.left,
  //     body.top + SettingsPerformanceSectionMetrics.firstHelpInsetTop,
  //     SettingsPerformanceSectionMetrics.helpSize, SettingsFontWeight.regular, 0, palette.muted);
  row(
      SettingsPerformanceSectionMetrics.secondRowTop,
      SettingsPerformanceContent.secondTitleEn,
      SettingsPerformanceContent.secondTitleZh,
      discRotation
          ? SettingsPerformanceContent.secondLabelOn
          : SettingsPerformanceContent.secondLabelOff,
      SettingsPerformanceContent.secondAction,
      SettingsPerformanceContent.secondHitLabel);
  canvas.text(SettingsPerformanceContent.secondHelp, body.left,
      body.top + SettingsPerformanceSectionMetrics.secondHelpInsetTop,
      SettingsPerformanceSectionMetrics.helpSize, SettingsFontWeight.regular, 0, palette.muted);
}

/// NativeHudSettings.cpp:332-342 的 storage 自定义区几何与文案。
class SettingsStorageContent {
  const SettingsStorageContent._();

  static const String titleEn = 'STORAGE';
  static const String titleZh = '存储与缓存';
  static const String action = 'cache:clear';
  static const String emptyLabel = '清除缓存';
  static const String hitLabel = '清除缓存';
  static const String help = '清理元数据、歌词、封面与列表缓存，保留主题和账号。';

  static const double titleInsetTop = 10;
  static const double titleSize = 11;
  static const double titleTracking = 0.08;
  static const double subtitleInsetTop = 25;
  static const double subtitleSize = 17;
  static const double subtitleTracking = -0.01;
  static const double controlInsetTop = 8;
  static const double controlHeight = 48;
  static const double ruleInsetTop = 62;
  static const double helpInsetTop = 72;
  static const double helpSize = 13;
}

/// NativeHudSettings.cpp:332-342。
void paintStorageSection({
  required Rect body,
  required String cacheMessage,
  required SettingsCanvas canvas,
  required SettingsPalette palette,
  SettingsTextFit fit = identitySettingsTextFit,
}) {
  final Rect control = Rect.fromLTWH(body.right - SettingsRowMetrics.controlWidth,
      body.top + SettingsStorageContent.controlInsetTop, SettingsRowMetrics.controlWidth,
      SettingsStorageContent.controlHeight);
  canvas.text(SettingsStorageContent.titleEn, body.left,
      body.top + SettingsStorageContent.titleInsetTop, SettingsStorageContent.titleSize,
      SettingsFontWeight.regular, SettingsStorageContent.titleTracking, palette.muted);
  canvas.text(SettingsStorageContent.titleZh, body.left,
      body.top + SettingsStorageContent.subtitleInsetTop, SettingsStorageContent.subtitleSize,
      SettingsFontWeight.demibold, SettingsStorageContent.subtitleTracking, palette.ink);
  // :338 label = cacheMessage.isEmpty() ? "清除缓存" : cacheMessage
  paintSettingsActionBlock(
    rect: control,
    label: storageCacheActionLabel(cacheMessage),
    action: SettingsStorageContent.action,
    hitLabel: SettingsStorageContent.hitLabel,
    canvas: canvas,
    palette: palette,
    fit: fit,
  );
  canvas.fill(body.left, body.top + SettingsStorageContent.ruleInsetTop, body.width, 1,
      palette.line);
  canvas.text(SettingsStorageContent.help, body.left,
      body.top + SettingsStorageContent.helpInsetTop, SettingsStorageContent.helpSize,
      SettingsFontWeight.regular, 0, palette.muted);
}

/// NativeHudSettings.cpp:344-370 的 update 自定义区几何与文案。
class SettingsUpdateContent {
  const SettingsUpdateContent._();

  static const String versionPrefix = '当前版本 / ';

  /// :347 buildLabel = RHINE_RELEASE_BUILD ? "" : " · 开发版"。
  static const String devBuildSuffix = ' · 开发版';
  static const String autoAction = 'update:auto';
  static const String autoHitLabel = '启动检查';
  static const String autoLabelOff = '启动检查 / 关闭';
  static const String autoLabelOn = '启动检查 / 开启';
  static const String checkAction = 'update:check';
  static const String cancelAction = 'update:cancel';
  static const String checkLabel = '检查更新';
  static const String cancelLabel = '取消';
  static const String checkHitLabel = '检查更新';
  static const String releaseAction = 'update:release';
  static const String releaseLabel = '前往更新 ↗';
  static const String releaseHitLabel = '前往更新';
  static const String notesLabel = '发布说明 ↗';
  static const String notesHitLabel = '发布说明';
  static const String help = '更新将打开 GitHub 发布页面，请在浏览器中下载并安装。';

  static const double versionInsetTop = 4;
  static const double versionSize = 18;
  static const double commitInsetTop = 32;
  static const double commitSize = 12;
  static const double autoInsetTop = 50;
  static const double autoHeight = 48;
  static const double statusInsetTop = 68;
  static const double statusSize = 13;
  static const double statusFitInset = 340;
  static const double checkInsetTop = 112;
  static const double checkWidth = 170;
  static const double checkHeight = 46;
  static const double releaseInsetLeft = 186;
  static const double releaseWidth = 210;
  static const double releaseHeight = 46;
  static const double notesInsetRight = 210;
  static const double helpInsetTop = 176;
  static const double helpSize = 12;
}

/// NativeHudSettings.cpp:344-370。
void paintUpdateSection({
  required Rect body,
  required String version,
  required String commitTitle,
  required bool releaseBuild,
  required String updaterStatus,
  required bool prefersAutoUpdate,
  required bool busy,
  required bool updateAvailable,
  required SettingsCanvas canvas,
  required SettingsPalette palette,
  SettingsTextFit fit = identitySettingsTextFit,
}) {
  // :346-347 "当前版本 / <version>" + 非发布构建追加 " · 开发版"
  canvas.text(
      SettingsUpdateContent.versionPrefix +
          version +
          (releaseBuild ? '' : SettingsUpdateContent.devBuildSuffix),
      body.left,
      body.top + SettingsUpdateContent.versionInsetTop,
      SettingsUpdateContent.versionSize,
      SettingsFontWeight.demibold,
      0,
      palette.ink);
  if (!releaseBuild) {
    // :349 非发布构建追加 commitTitle（12pt muted）
    canvas.text(commitTitle, body.left, body.top + SettingsUpdateContent.commitInsetTop,
        SettingsUpdateContent.commitSize, SettingsFontWeight.regular, 0, palette.muted);
  }
  // :351 autoUpdate = QRectF(body.right() - 300, body.top() + 50, 300, 48)
  paintSettingsActionBlock(
    rect: Rect.fromLTWH(body.right - SettingsRowMetrics.controlWidth,
        body.top + SettingsUpdateContent.autoInsetTop, SettingsRowMetrics.controlWidth,
        SettingsUpdateContent.autoHeight),
    label: prefersAutoUpdate
        ? SettingsUpdateContent.autoLabelOn
        : SettingsUpdateContent.autoLabelOff,
    action: SettingsUpdateContent.autoAction,
    hitLabel: SettingsUpdateContent.autoHitLabel,
    canvas: canvas,
    palette: palette,
    fit: fit,
  );
  // :353 updater.status() 13pt muted
  canvas.text(
      fit(updaterStatus, SettingsUpdateContent.statusSize,
          body.width - SettingsUpdateContent.statusFitInset, SettingsFontWeight.regular),
      body.left,
      body.top + SettingsUpdateContent.statusInsetTop,
      SettingsUpdateContent.statusSize,
      SettingsFontWeight.regular,
      0,
      palette.muted);
  // :355-361 检查 / 取消块
  paintSettingsActionBlock(
    rect: Rect.fromLTWH(body.left, body.top + SettingsUpdateContent.checkInsetTop,
        SettingsUpdateContent.checkWidth, SettingsUpdateContent.checkHeight),
    label: busy ? SettingsUpdateContent.cancelLabel : SettingsUpdateContent.checkLabel,
    action: busy ? SettingsUpdateContent.cancelAction : SettingsUpdateContent.checkAction,
    hitLabel: SettingsUpdateContent.checkHitLabel,
    canvas: canvas,
    palette: palette,
    fit: fit,
  );
  // :362-365 仅 !busy && available 时绘制"前往更新"
  if (!busy && updateAvailable) {
    paintSettingsActionBlock(
      rect: Rect.fromLTWH(body.left + SettingsUpdateContent.releaseInsetLeft,
          body.top + SettingsUpdateContent.checkInsetTop, SettingsUpdateContent.releaseWidth,
          SettingsUpdateContent.releaseHeight),
      label: SettingsUpdateContent.releaseLabel,
      action: SettingsUpdateContent.releaseAction,
      hitLabel: SettingsUpdateContent.releaseHitLabel,
      canvas: canvas,
      palette: palette,
      fit: fit,
    );
  }
  // :366-369 无条件"发布说明"，不得并入上面的条件行
  paintSettingsActionBlock(
    rect: Rect.fromLTWH(body.right - SettingsUpdateContent.notesInsetRight,
        body.top + SettingsUpdateContent.checkInsetTop, SettingsUpdateContent.releaseWidth,
        SettingsUpdateContent.releaseHeight),
    label: SettingsUpdateContent.notesLabel,
    action: SettingsUpdateContent.releaseAction,
    hitLabel: SettingsUpdateContent.notesHitLabel,
    canvas: canvas,
    palette: palette,
    fit: fit,
  );
  // :370 帮助文本 12pt
  canvas.text(SettingsUpdateContent.help, body.left,
      body.top + SettingsUpdateContent.helpInsetTop, SettingsUpdateContent.helpSize,
      SettingsFontWeight.regular, 0, palette.muted);
}

/// NativeHudSettings.cpp:372-379 的 footer（defaults）自定义区。
class SettingsDefaultsContent {
  const SettingsDefaultsContent._();

  static const String label = '恢复默认设置';
  static const String action = 'settings:restore-defaults';
  static const String hitLabel = '恢复默认设置';
  static const String help = '仅重置终端偏好，平台、账号与更新状态保持不变。';

  static const double blockInsetTop = 6;
  static const double blockWidth = 300;
  static const double blockHeight = 46;
  static const double helpInsetLeft = 316;
  static const double helpInsetTop = 20;
  static const double helpSize = 12;
}

/// NativeHudSettings.cpp:372-379。
void paintDefaultsSection({
  required Rect body,
  required SettingsCanvas canvas,
  required SettingsPalette palette,
  SettingsTextFit fit = identitySettingsTextFit,
}) {
  paintSettingsActionBlock(
    rect: Rect.fromLTWH(body.left, body.top + SettingsDefaultsContent.blockInsetTop,
        SettingsDefaultsContent.blockWidth, SettingsDefaultsContent.blockHeight),
    label: SettingsDefaultsContent.label,
    action: SettingsDefaultsContent.action,
    hitLabel: SettingsDefaultsContent.hitLabel,
    canvas: canvas,
    palette: palette,
    fit: fit,
  );
  canvas.text(SettingsDefaultsContent.help, body.left + SettingsDefaultsContent.helpInsetLeft,
      body.top + SettingsDefaultsContent.helpInsetTop, SettingsDefaultsContent.helpSize,
      SettingsFontWeight.regular, 0, palette.muted);
}

/// 自定义区绘制所需的运行时状态（对应 Qt 的 MusicLibrary / MusicPlayer / AppUpdater / preference）。
class SettingsCustomSectionState {
  const SettingsCustomSectionState({
    this.provider = const SettingsProviderState(providerId: 'siren', providerName: '塞壬唱片'),
    this.discRotation = false,
    this.prefersAutoUpdate = true,
    this.cacheMessage = '',
    this.version = '',
    this.releaseBuild = true,
    this.commitTitle = '',
    this.updaterStatus = '',
    this.busy = false,
    this.updateAvailable = false,
  });

  final SettingsProviderState provider;

  /// MusicPlayer::discRotation（:324）。
  final bool discRotation;

  /// preference("auto-update") != "off"（:352）。
  final bool prefersAutoUpdate;

  /// 缓存状态文案（:338）。
  final String cacheMessage;

  final String version;
  final bool releaseBuild;
  final String commitTitle;
  final String updaterStatus;
  final bool busy;
  final bool updateAvailable;

  @override
  String toString() => 'SettingsCustomSectionState(${provider.providerId})';
}

/// NativeHudSettings.cpp:227-380 的 custom() 分发。:228 Q_UNUSED(scroll)：
/// 系统滚动已在 paintSettingsCard 中把 body 上移，这里不再重复平移。
void paintSettingsCustomSection({
  required String renderer,
  required Rect body,
  required double scroll,
  required SettingsCustomSectionState state,
  required SettingsCanvas canvas,
  required SettingsPalette palette,
  SettingsTextFit fit = identitySettingsTextFit,
}) {
  if (renderer == SettingsCustomRenderers.performance) {
    paintPerformanceSection(
        body: body,
        discRotation: state.discRotation,
        canvas: canvas,
        palette: palette,
        fit: fit);
    return;
  }
  if (renderer == SettingsCustomRenderers.storage) {
    paintStorageSection(
        body: body, cacheMessage: state.cacheMessage, canvas: canvas, palette: palette, fit: fit);
    return;
  }
  if (renderer == SettingsCustomRenderers.update) {
    paintUpdateSection(
      body: body,
      version: state.version,
      commitTitle: state.commitTitle,
      releaseBuild: state.releaseBuild,
      updaterStatus: state.updaterStatus,
      prefersAutoUpdate: state.prefersAutoUpdate,
      busy: state.busy,
      updateAvailable: state.updateAvailable,
      canvas: canvas,
      palette: palette,
      fit: fit,
    );
    return;
  }
  if (renderer == SettingsCustomRenderers.defaults) {
    paintDefaultsSection(body: body, canvas: canvas, palette: palette, fit: fit);
    return;
  }
  paintProviderCardSection(
      body: body, state: state.provider, canvas: canvas, palette: palette, fit: fit);
}

/// SettingsCard.cpp:36-45 drawSectionHeader 的常量。
class SettingsHeaderMetrics {
  const SettingsHeaderMetrics._();

  /// :40 序号 11pt muted tracking 0.05，绘于 header.left() + ContentInset，top + 12。
  static const double indexSize = 11;
  static const double indexTracking = 0.05;
  static const double indexInsetTop = 12;

  /// :42-43 标题 titleEn + " / " + titleZh，14pt demibold tracking 0.06，left + 26 / top + 9。
  static const double titleSize = 14;
  static const double titleTracking = 0.06;
  static const double titleInsetLeft = 26;
  static const double titleInsetTop = 9;
}

/// SettingsCard.cpp:36-45 drawSectionHeader 逐字。
void paintSettingsSectionHeader({
  required SettingsSectionLayout section,
  required SettingsCanvas canvas,
  required SettingsPalette palette,
  double scroll = 0,
}) {
  final Rect header = section.header.translate(0, -scroll);
  final double left = header.left + SettingsRowMetrics.contentInset;
  final double width = header.width - SettingsRowMetrics.contentInset * 2;
  // :40 QString::number(section.section->meta->number).rightJustified(2, '0')
  canvas.text(section.section.numberText, left,
      header.top + SettingsHeaderMetrics.indexInsetTop, SettingsHeaderMetrics.indexSize,
      SettingsFontWeight.regular, SettingsHeaderMetrics.indexTracking, palette.muted);
  // :43 titleEn + " / " + titleZh
  canvas.text(section.section.titleText, left + SettingsHeaderMetrics.titleInsetLeft,
      header.top + SettingsHeaderMetrics.titleInsetTop, SettingsHeaderMetrics.titleSize,
      SettingsFontWeight.demibold, SettingsHeaderMetrics.titleTracking, palette.ink);
  // :44 fill(left, header.bottom() - 1, width, 1, line)
  canvas.fill(left, header.bottom - 1, width, 1, palette.line);
}

/// SettingsCard.cpp:294-327 paint() 逐条：表头 / 自定义区 / 行 / 独立展开的选项区。
/// 行的可见性判定与逐行绘制复用 A1 的 paintSettingsRowLayer / paintSettingsOptions。
void paintSettingsCard({
  required SettingsCardLayout layout,
  required double scroll,
  required SettingsCanvas canvas,
  required SettingsPalette palette,
  required SettingsCustomSectionState custom,
  SettingsTextFit fit = identitySettingsTextFit,
}) {
  for (final SettingsSectionLayout section in layout.sections) {
    final SettingsSectionLayout moved = section.translated(-scroll);
    // :299 header.overlaps(viewport) 才画表头
    if (moved.header.overlaps(layout.viewport)) {
      paintSettingsSectionHeader(section: moved, canvas: canvas, palette: palette);
    }
    // :300-305 自定义区：body 可见才分发给渲染器
    if (moved.section.hasCustomRenderer) {
      if (moved.body.overlaps(layout.viewport)) {
        paintSettingsCustomSection(
          renderer: moved.section.customRenderer,
          body: moved.body,
          scroll: scroll,
          state: custom,
          canvas: canvas,
          palette: palette,
          fit: fit,
        );
      }
      continue;
    }
    // :307-326 普通行
    for (int index = 0; index < moved.rows.length; index++) {
      final SettingsRowLayout row = moved.rows[index];
      final bool rowVisible = row.bounds.overlaps(layout.viewport);
      final bool optionsVisible =
          row.row.expanded && row.options.overlaps(layout.viewport);
      if (rowVisible) {
        paintSettingsRowLayer(
            layout: row,
            index: index,
            canvas: canvas,
            palette: palette,
            viewport: layout.viewport,
            fit: fit);
      } else if (optionsVisible) {
        paintSettingsOptions(layout: row, canvas: canvas, palette: palette, fit: fit);
      }
    }
  }
}

/// NativeHudSettings.cpp:205-210：绘制前记录 firstHit = hits.size()，绘制后
/// HudScroll::clipHits(hits, firstHit, viewport) —— first 之前的命中原样保留（HudScroll.h:67-86）。
/// 调用顺序必须与 Qt 一致：先取 recorder.hits.length，再 paintSettingsCard，再本函数。
List<SettingsHitRegion> clipSettingsPanelHits(List<SettingsHitRegion> hits, Rect viewport,
        {int first = 0}) =>
    clipSettingsHits(hits, viewport, first: first);

/// NativeHudSettings.cpp:218-221 的轨道配色。
class SettingsRailMetrics {
  const SettingsRailMetrics._();

  static const SettingsRgba trackDark = SettingsRgba(1, 1, 1, 0.1);
  static const SettingsRgba trackLight = SettingsRgba(0, 0, 0, 0.1);
  static const SettingsRgba thumbDark = SettingsRgba(1, 1, 1, 0.45);
  static const SettingsRgba thumbLight = SettingsRgba(0, 0, 0, 0.4);

  static SettingsRgba track(bool dark) => dark ? trackDark : trackLight;
  static SettingsRgba thumb(bool dark) => dark ? thumbDark : thumbLight;
}

/// NativeHud.cpp:110-120 的 button() 模态分支：先记命中，再铺底色，
/// 最后把 fit(label, size, width - 2 * inset) 左对齐画在 (x + inset, y + (height - size) / 2 - 4)。
void _paintModalButton({
  required SettingsCanvas canvas,
  required SettingsPalette palette,
  required Rect rect,
  required String label,
  required double size,
  required SettingsFontWeight weight,
  required String action,
  required bool dark,
  required SettingsTextFit fit,
}) {
  canvas.hit(rect.left, rect.top, rect.width, rect.height, action, label);
  final double inset = SettingsModalMetrics.modalButtonInset(rect.width);
  canvas.fill(rect.left, rect.top, rect.width, rect.height, SettingsModalMetrics.modalButtonTint(dark));
  // NativeHud.cpp:118-119 的 text() 不传色 → ink()。
  canvas.text(fit(label, size, rect.width - 2 * inset, weight), rect.left + inset,
      SettingsModalMetrics.modalButtonTextY(rect.top, rect.height, size), size, weight, 0,
      palette.ink);
}

/// NativeHudSettings.cpp:163-225 的整块面板：卡片 + 滚动轨道 + 两个滚动按钮。
void paintSettingsPanel({
  required double x,
  required double y,
  required double width,
  required SettingsCardLayout layout,
  required double scroll,
  required SettingsCanvas canvas,
  required SettingsPalette palette,
  required SettingsCustomSectionState custom,
  SettingsTextFit fit = identitySettingsTextFit,
  bool dark = false,
}) {
  paintSettingsCard(
      layout: layout, scroll: scroll, canvas: canvas, palette: palette, custom: custom, fit: fit);
  // :212-222 轨道与 thumb
  final Rect track = SettingsPanelGeometry.scrollTrack(x: x, y: y, width: width);
  canvas.fill(track.left, track.top, track.width, track.height, SettingsRailMetrics.track(dark));
  final SettingsScrollRail rail = settingsScrollRail(
      track: track,
      contentHeight: layout.contentHeight,
      viewportHeight: layout.viewport.height,
      offset: scroll);
  if (rail.visible) {
    canvas.fill(rail.thumb.left, rail.thumb.top, rail.thumb.width, rail.thumb.height,
        SettingsRailMetrics.thumb(dark));
  }
  // :223-224 滚动按钮：m_modalControls=true → 底色 + inset=min(10, 23/8)=2.875 + 左对齐。
  _paintModalButton(
      canvas: canvas,
      palette: palette,
      rect: SettingsPanelGeometry.scrollUpButton(track: track, y: y),
      label: SettingsPanelGeometry.scrollUpGlyph,
      size: SettingsModalMetrics.scrollButtonTextSize,
      weight: SettingsFontWeight.regular,
      action: SettingsPanelGeometry.scrollUpAction,
      dark: dark,
      fit: fit);
  _paintModalButton(
      canvas: canvas,
      palette: palette,
      rect: SettingsPanelGeometry.scrollDownButton(track: track, y: y),
      label: SettingsPanelGeometry.scrollDownGlyph,
      size: SettingsModalMetrics.scrollButtonTextSize,
      weight: SettingsFontWeight.regular,
      action: SettingsPanelGeometry.scrollDownAction,
      dark: dark,
      fit: fit);
}

/// NativeHudModal.cpp:188-202 的设置模态框架常量。
class SettingsModalFrame {
  const SettingsModalFrame._();

  /// :198 "RHINE LAB / MUSIC DATABASE / " + category，settings 的 category = "SYSTEM PREFERENCES"。
  static const String categoryPrefix = 'RHINE LAB / MUSIC DATABASE / ';
  static const String category = 'SYSTEM PREFERENCES';
  static const String categoryText = 'RHINE LAB / MUSIC DATABASE / SYSTEM PREFERENCES';

  /// :201 modalTitle("settings") —— NativeHudModal.cpp:28。
  static const String title = 'SYSTEM SETTINGS';

  /// :202 modalSubtitle("settings") —— NativeHudModal.cpp:54。
  static const String subtitle = '终端偏好设置';

  /// :199-200 button("← 返回", ..., "close-modal", 20, "demibold")。
  static const String backLabel = '← 返回';
  static const String backAction = 'close-modal';

  /// :198 settings 用 14pt（其余 modal 11pt）；:202 settings 用 18pt（其余 15pt）；:201 恒 38pt demibold。
  static const double categorySize = 14;
  static const double titleSize = 38;
  static const double subtitleSize = 18;
  static const double backTextSize = 20;
}

/// NativeHud.cpp:140-159 的 modalBounds：settings 走默认分支
/// （modalWidth = min(1260, width - 100)，left = (width - modalWidth) / 2，y = 122，高 836）。
Rect settingsModalBounds(double width) {
  final double modalWidth = math.min(
      SettingsModalMetrics.modalMaxWidth, width - SettingsModalMetrics.modalSideInset);
  final double left = (width - modalWidth) / 2;
  return Rect.fromLTWH(
      left, SettingsModalMetrics.modalTop, modalWidth, SettingsModalMetrics.panelHeight);
}

/// NativeHudModal.cpp:163-172 的遮罩 + 面板底：先铺满整幅画面的遮罩，
/// 再在 modalBounds 上铺面板底色。painter 顺序与 Qt 一致（遮罩 → 面板 → 文本 → 卡片）。
void paintSettingsModalBackdrop({
  required double width,
  required Rect bounds,
  required SettingsCanvas canvas,
  bool dark = false,
}) {
  // :163-165 fill(0, 0, width, 1080, ...)。
  canvas.fill(0, 0, width, SettingsModalMetrics.stageHeight, SettingsModalMetrics.mask(dark));
  // :171-172 fill(x, y, usable, 836, ...)。
  canvas.fill(bounds.left, bounds.top, bounds.width, SettingsModalMetrics.panelHeight,
      SettingsModalMetrics.panel(dark));
}

/// NativeHudModal.cpp:188-202 的框架绘制（第 3 段新增；不绘制卡片本体）。
/// Qt 这三行 text() 与返回按钮的 button() 都不传颜色，走 NativeHud::text 的默认 ink()
/// （NativeHud.cpp:40-43）——因此这里没有任何颜色参数。
void paintSettingsModalFrame({
  required double x,
  required double y,
  required double usable,
  required SettingsCanvas canvas,
  required SettingsPalette palette,
  bool dark = false,
  SettingsTextFit fit = identitySettingsTextFit,
}) {
  // :198 text("RHINE LAB / MUSIC DATABASE / " + category, x + 53, y + 37, 14)（无 weight 参数 → regular）
  canvas.text(SettingsModalFrame.categoryText, x + SettingsModalMetrics.categoryX,
      y + SettingsModalMetrics.categoryY, SettingsModalFrame.categorySize,
      SettingsFontWeight.regular, 0, palette.ink);
  // :201 text(modalTitle, x + 53, y + 91, 38, "demibold")
  canvas.text(SettingsModalFrame.title, x + SettingsModalMetrics.categoryX,
      y + SettingsModalMetrics.titleY, SettingsModalFrame.titleSize, SettingsFontWeight.demibold,
      0, palette.ink);
  // :202 text(modalSubtitle, x + 53, y + 147, 18)
  canvas.text(SettingsModalFrame.subtitle, x + SettingsModalMetrics.categoryX,
      y + SettingsModalMetrics.subtitleY, SettingsModalFrame.subtitleSize,
      SettingsFontWeight.regular, 0, palette.ink);
  // :199-200 button("← 返回", x + usable - 220, y + 18, 167, 54, "close-modal", 20, "demibold")：
  // m_modalControls=true → 底色 + inset=min(10, 167/8)=10 + 左对齐 fit(label, 20, 147)。
  _paintModalButton(
      canvas: canvas,
      palette: palette,
      rect: SettingsPanelGeometry.backButton(x: x, y: y, usable: usable),
      label: SettingsModalFrame.backLabel,
      size: SettingsModalFrame.backTextSize,
      weight: SettingsFontWeight.demibold,
      action: SettingsModalFrame.backAction,
      dark: dark,
      fit: fit);
}

/// Overlay.qml:563-602 的设置编辑浮层几何。
class SettingsEditOverlayGeometry {
  const SettingsEditOverlayGeometry({
    required this.stageScale,
    required this.background,
    required this.text,
    required this.fontSize,
  });

  final double stageScale;

  /// :565-569 background = (x*scale, (y + modalOffset)*scale, w*scale, h*scale)。
  final Rect background;

  /// :576-579 input = (bg.x + 12*scale, bg.y, max(0, bg.width - 24*scale), bg.height)。
  final Rect text;

  /// :581 font.pixelSize = 16 * stageScale。
  final double fontSize;

  @override
  String toString() => 'SettingsEditOverlayGeometry($background)';
}

/// :564-602 的编辑浮层几何纯函数（无 Flutter widget 依赖）。
SettingsEditOverlayGeometry settingsEditOverlay({
  required Rect settingRect,
  required double modalOffset,
  double stageScale = 1,
}) {
  final Rect background = Rect.fromLTWH(settingRect.left * stageScale,
      (settingRect.top + modalOffset) * stageScale, settingRect.width * stageScale,
      settingRect.height * stageScale);
  final double inset = SettingsEditOverlayMetrics.textInset * stageScale;
  return SettingsEditOverlayGeometry(
    stageScale: stageScale,
    background: background,
    text: Rect.fromLTWH(background.left + inset, background.top,
        math.max(0, background.width - inset * 2), background.height),
    fontSize: SettingsEditOverlayMetrics.textSize * stageScale,
  );
}

/// Overlay.qml:564-602 的编辑浮层常量与配色。
class SettingsEditOverlayMetrics {
  const SettingsEditOverlayMetrics._();

  /// :576 x = bg.x + 12*stageScale；:578 width = max(0, bg.width - 24*stageScale)。
  static const double textInset = 12;

  /// :581 font.pixelSize = 16*stageScale。
  static const double textSize = 16;

  /// :574 border.width = 1*stageScale。
  static const double borderWidth = 1;

  /// :594 Accessible.name = "设置文本"。
  static const String accessibleName = '设置文本';

  /// :575 TextInput 的 objectName。
  static const String objectName = 'musicSettingEditInput';

  /// :570-572 / :573 背景色与边框色。
  static const SettingsRgba backgroundDark = SettingsRgba(0x2b / 255, 0x33 / 255, 0x2c / 255, 1);
  static const SettingsRgba backgroundLight = SettingsRgba(0xe5 / 255, 0xe7 / 255, 0xda / 255, 1);
  static const SettingsRgba borderDark = SettingsRgba(0x4a / 255, 0x55 / 255, 0x4b / 255, 1);
  static const SettingsRgba borderLight = SettingsRgba(0xaa / 255, 0xb0 / 255, 0xa0 / 255, 1);

  /// :583 文本色。
  static const SettingsRgba textDark = SettingsRgba(0xe9 / 255, 0xe7 / 255, 0xda / 255, 1);
  static const SettingsRgba textLight = SettingsRgba(0x22 / 255, 0x2a / 255, 0x25 / 255, 1);

  static SettingsRgba background(bool dark) => dark ? backgroundDark : backgroundLight;
  static SettingsRgba border(bool dark) => dark ? borderDark : borderLight;
  static SettingsRgba textColor(bool dark) => dark ? textDark : textLight;
}

// 8. 性能面板本体规格（PerformancePanel.qml:1-150）—— 保留，不在设置七区内渲染

// 面板已停用；以下仅保留关键尺寸供恢复参考。

//   /// :16-17 anchors.top/right parent, margins 12；:18 width 366；:19 height content.height + 24。

//   /// :20 radius 8；:21-22 底色与描边。

//   /// :32-35 content x/y 12，spacing 9。

//   /// :39-41 headline 21pt bold。

//   /// :50-61 details 12pt / lineHeight 1.35 / 可视高 min(h, max(80, panel.height - 210))。

//   /// :64-147 四按钮：高 30、radius 4、文字 12pt、间距 6。

//   /// objectName / 文案 / Accessible.name 逐字。

//   /// :19 卡片高 = content.height + 24。

//   /// :48 height = min(details.height, max(80, panel.height - 210))。

//   /// :66 Row 四按钮的顺序与宽度。

// /// 性能面板按钮：文案 + 矩形 + 底色 + 无障碍名。

//   final String label;

//   @override

// /// PerformancePanel.qml:64-147 的横向按钮行（起点 x/y 为按钮行左缘与顶缘）。

// // ---------------------------------------------------------------------------
// 9. 偏好 descriptor 注册表（Qt/src/SettingsSchema.cpp:347-691）
//    以及 Host::preferenceKeys() 的 53 个 key 白名单（Qt/src/Host.cpp:1041-1059）。
//    Qt 用 Q_OS_* 宏与 PlatformFeatures 做平台门；Flutter 侧把平台身份和五项能力
//    都显式放进 SettingsPreferenceContext，避免读全局状态。

/// Qt 的 Q_OS_* 身份（SettingsSchema.cpp:96-244 的 #ifdef 分支）。
enum SettingsOperatingSystem { android, iOS, windows, macOS, linux }

/// StorageType（Qt/src/SettingsSchema.h:61-78）逐值对应。
/// Qt 的 Enum 在 Dart 是保留字，故记作 enumeration。
enum SettingsStorageType {
  none,
  onOff,
  reducedFull,
  theme,
  trayQuit,
  appendReplace,
  integer,
  enumeration,
  playerQuality,
  playerAlternative,
  externalBool,
  hudCachedInt,
  hudCachedBool,
  capability,
  updater,
}

/// SettingDescriptor（Qt/src/SettingsSchema.h:80-124）的只读投影。
/// 只保留行模型与注册表校验需要的字段；description 在 Qt 侧从未赋值。
class SettingsDescriptor {
  const SettingsDescriptor({
    required this.id,
    required this.section,
    required this.kind,
    this.bindingKind = SettingsBindingKind.preference,
    this.storage = SettingsStorageType.none,
    required this.order,
    required this.titleEn,
    required this.titleZh,
    this.darwinTitleEn = '',
    this.darwinTitleZh = '',
    this.description = '',
    this.actionLabel = '',
    this.restartHint = '',
    this.darwinRestartHint = '',
    this.defaultValue = '',
    this.preferenceKey = '',
    this.action = '',
    this.actionPrefix = '',
    this.choices = const <SettingsChoice>[],
    this.choicesFor,
    this.minimum = 0,
    this.maximum = 0,
    this.step = 0,
    this.steps = const <int>[],
    this.wrap = false,
    this.visible,
    this.enabled,
    this.label,
  });

  final String id;
  final SettingsSectionId section;
  final SettingsRowKind kind;
  final SettingsBindingKind bindingKind;
  final SettingsStorageType storage;
  final int order;
  final String titleEn;
  final String titleZh;

  /// SettingsSchema.cpp:220/260 在 Q_OS_DARWIN 下换掉标题与副标题。
  final String darwinTitleEn;
  final String darwinTitleZh;
  final String description;
  final String actionLabel;

  /// SettingsSchema.cpp:220/230/240 的 restartHint（graphics-backend 仅非 Darwin 有）。
  final String restartHint;
  final String darwinRestartHint;
  final String defaultValue;
  final String preferenceKey;
  final String action;
  final String actionPrefix;
  final List<SettingsChoice> choices;
  final SettingsChoicesResolver? choicesFor;
  final int minimum;
  final int maximum;
  final int step;
  final List<int> steps;
  final bool wrap;
  final SettingsPredicate? visible;
  final SettingsPredicate? enabled;
  final SettingsLabelResolver? label;

  @override
  String toString() => 'SettingsDescriptor($id, order: $order)';
}

/// 行解析用的一次读取结果（Qt SettingsValue：raw / canonical / boolean / integer / valid / isDefault）。
class SettingsPreferenceValue {
  const SettingsPreferenceValue({
    this.raw = '',
    this.canonical = '',
    this.integer = 0,
    this.boolean = false,
    this.valid = false,
    this.isDefault = false,
  });

  final String raw;
  final String canonical;
  final int integer;
  final bool boolean;
  final bool valid;
  final bool isDefault;

  @override
  String toString() => 'SettingsPreferenceValue($canonical, $integer)';
}

/// 平台身份 + 平台能力 + 派生状态（Qt SettingsContext 的可见部分）。
class SettingsPreferenceContext {
  const SettingsPreferenceContext({
    this.capabilities = const PlatformCapabilities.windows(),
    this.operatingSystem = SettingsOperatingSystem.windows,
    this.providerId = 'netease',
    this.musicEnabled = true,
    this.providerIsLocal = false,
    this.gpuDeviceCount = 1,
    this.direct3d12Available = false,
    this.temporalAntialiasingAvailable = true,
    this.frameGenerationClickable = true,
    this.frameGenerationLabel = '关闭',
    this.aaMode = 'off',
    this.appliedGraphicsBackend = '',
    this.gpuAppliedIndex = -1,
  });

  final PlatformCapabilities capabilities;
  final SettingsOperatingSystem operatingSystem;
  final String providerId;
  final bool musicEnabled;
  final bool providerIsLocal;
  final int gpuDeviceCount;
  final bool direct3d12Available;
  final bool temporalAntialiasingAvailable;
  final bool frameGenerationClickable;
  final String frameGenerationLabel;

  /// NativeHudSettings.cpp:14 的 host->preference("aa-mode")。
  final String aaMode;

  /// RhineGraphics::activeBackend()（:238 的 applied）。
  final String appliedGraphicsBackend;

  /// RhineGraphics::gpuAppliedIndex()（:257）。
  final int gpuAppliedIndex;

  bool get isDarwin =>
      operatingSystem == SettingsOperatingSystem.macOS || operatingSystem == SettingsOperatingSystem.iOS;
  bool get isLinux => operatingSystem == SettingsOperatingSystem.linux;
  bool get isWindows => operatingSystem == SettingsOperatingSystem.windows;
  bool get isMacOS => operatingSystem == SettingsOperatingSystem.macOS;
}

/// SettingsSchema::read() 需要的宿主状态快照（Qt 侧直接读 host/player 成员）。
class SettingsPreferenceSnapshot {
  const SettingsPreferenceSnapshot({
    this.preferences = const <String, String>{},
    this.themeMode = 'light',
    this.reducedMotion = false,
    this.startupAnimation = false,
    this.discRotation = false,
    this.vsync = true,
    this.archiveMaskStrength = 50,
    this.quality = 'exhigh',
    this.alternative = false,
    this.officialPlayerActive = false,
  });

  final Map<String, String> preferences;
  final String themeMode;
  final bool reducedMotion;
  final bool startupAnimation;
  final bool discRotation;
  final bool vsync;
  final int archiveMaskStrength;
  final String quality;
  final bool alternative;
  final bool officialPlayerActive;

  /// Host::preference()：离线或不在白名单时返回空串（Host.cpp:1055-1059）。
  String preference(String key) => preferences[key] ?? '';
}

typedef SettingsPredicate = bool Function(SettingsPreferenceContext context);
typedef SettingsChoicesResolver = List<SettingsChoice> Function(SettingsPreferenceContext context);
typedef SettingsLabelResolver = String Function(SettingsPreferenceContext context, SettingsPreferenceValue value);

// 9.1 Host::preferenceKeys() 白名单：Qt/src/Host.cpp:1041-1059 的 53 个 key。
//     Host::preference() 对白名单外的 key 一律返回空串；写入落在 panel/<key>。

const List<String> settingsPreferenceKeys = <String>[
  'search-history',
  'play-history',
  'local-cover-cache',
  'theme',
  'motion',
  'startup-animation',
  'detail-autoplay',
  'single-play-mode',
  'disc-rotation',
  'scene-enhancement',
  'archive-mask-strength',
  'graphics-backend',
  'gpu-index',
  'vsync',
  'supersample',
  'render-scale',
  'aa-mode',
  'aa-scale',
  'msaa',
  'fsr-quality',
  'fsr-sharpness',
  'fg',
  'close-behavior',
  'auto-update',
  'volume',
  'quality',
  'alternate-source',
  'provider',
  'lyrics-cache',
  'lyrics-global-offset-ms',
  'welcome-name-netease',
  'welcome-name-qq',
  'welcome-name-kugou',
  'account-id-netease',
  'account-id-qq',
  'account-id-kugou',
  'kugou-edition',
  'desktop-lyrics',
  'desktop-lyrics-size',
  'desktop-lyrics-translation-size',
  'desktop-lyrics-opacity',
  'desktop-lyrics-line-color',
  'desktop-lyrics-translation-color',
  'desktop-lyrics-line-weight',
  'desktop-lyrics-translation-weight',
  'desktop-lyrics-line-outline',
  'desktop-lyrics-translation-outline',
  'desktop-lyrics-line-outline-color',
  'desktop-lyrics-translation-outline-color',
  'welcome-name-kugou-standard',
  'welcome-name-kugou-lite',
  'account-id-kugou-standard',
  'account-id-kugou-lite',
];

final Set<String> settingsPreferenceKeySet = Set<String>.unmodifiable(settingsPreferenceKeys);

/// SettingsSchema::validateRegistry() 用它拒绝不在 Host 白名单里的偏好 key。
bool isSettingsPreferenceKey(String key) => settingsPreferenceKeySet.contains(key);

// 9.2 选项表（SettingsSchema.cpp:16-60）。值与文案逐字。

const List<SettingsChoice> settingsOnOffChoices = <SettingsChoice>[
  SettingsChoice(value: 'off', label: '关闭'),
  SettingsChoice(value: 'on', label: '开启'),
];

const List<SettingsChoice> settingsThemeChoices = <SettingsChoice>[
  SettingsChoice(value: 'light', label: '亮色'),
  SettingsChoice(value: 'dark', label: '暗色'),
  SettingsChoice(value: 'system', label: '跟随系统'),
];

const List<SettingsChoice> settingsMotionChoices = <SettingsChoice>[
  SettingsChoice(value: 'full', label: '完整动效'),
  SettingsChoice(value: 'reduced', label: '减少动效'),
];

const List<SettingsChoice> settingsTrayQuitChoices = <SettingsChoice>[
  SettingsChoice(value: 'quit', label: '退出播放器'),
  SettingsChoice(value: 'tray', label: '最小化到托盘'),
];

const List<SettingsChoice> settingsAppendReplaceChoices = <SettingsChoice>[
  SettingsChoice(value: 'replace', label: '替换为所在列表'),
  SettingsChoice(value: 'append', label: '仅添加当前单曲'),
];

const List<SettingsChoice> settingsAlternativeChoices = <SettingsChoice>[
  SettingsChoice(value: 'off', label: '关闭（使用平台默认音质）'),
  SettingsChoice(value: 'on', label: '开启（音质由来源决定）'),
];

const List<SettingsChoice> settingsFsrChoices = <SettingsChoice>[
  SettingsChoice(value: 'native', label: '原生 AA'),
  SettingsChoice(value: 'quality', label: '高质量'),
  SettingsChoice(value: 'balanced', label: '平衡'),
  SettingsChoice(value: 'performance', label: '性能'),
  SettingsChoice(value: 'super', label: '超级性能'),
];

// 9.3 平台门（SettingsSchema.cpp:96-244）与派生选项/标签。

bool settingsDesktopWindowVisible(SettingsPreferenceContext context) =>
    context.capabilities.desktopWindowControls;
bool settingsDesktopLyricsVisible(SettingsPreferenceContext context) =>
    context.capabilities.desktopLyrics;
bool settingsCloseVisible(SettingsPreferenceContext context) => context.isMacOS || context.isWindows;
bool settingsQualityVisible(SettingsPreferenceContext context) =>
    context.musicEnabled && !context.providerIsLocal;
bool settingsAlternativeVisible(SettingsPreferenceContext context) =>
    context.musicEnabled && !context.providerIsLocal && context.providerId == 'netease';
bool settingsOfficialPlayerVisible(SettingsPreferenceContext context) =>
    context.capabilities.officialPlayback && context.musicEnabled && !context.providerIsLocal;
bool settingsVsyncVisible(SettingsPreferenceContext context) => !context.isDarwin;
bool settingsGpuVisible(SettingsPreferenceContext context) => context.isLinux && context.gpuDeviceCount > 1;
bool settingsGraphicsEnabled(SettingsPreferenceContext context) => !context.isDarwin;
bool settingsAaScaleVisible(SettingsPreferenceContext context) =>
    !context.isDarwin && context.aaMode == 'ssaa';
bool settingsMsaaVisible(SettingsPreferenceContext context) => !context.isDarwin && context.aaMode == 'msaa';
bool settingsFsrVisible(SettingsPreferenceContext context) =>
    !context.isDarwin &&
    (context.aaMode == 'fsr' || context.aaMode == 'fsr1' || context.aaMode == 'fsr3');
bool settingsAaEnabled(SettingsPreferenceContext context) =>
    context.isDarwin ? context.temporalAntialiasingAvailable : true;
bool settingsFgVisible(SettingsPreferenceContext context) => context.isDarwin;
bool settingsFgEnabled(SettingsPreferenceContext context) => context.frameGenerationClickable;

/// MusicPlayer::qualityOptions(provider)（Qt/src/MusicPlayer.cpp:104-124）逐条。
List<SettingsChoice> settingsQualityChoices(SettingsPreferenceContext context) {
  if (!context.musicEnabled) {
    return const <SettingsChoice>[];
  }
  if (context.providerId == 'qq') {
    return const <SettingsChoice>[
      SettingsChoice(value: 'best', label: '自动最高可用'),
      SettingsChoice(value: 'standard', label: '标准'),
      SettingsChoice(value: 'exhigh', label: 'HQ 高品质'),
      SettingsChoice(value: 'lossless', label: 'SQ 无损 / FLAC'),
      SettingsChoice(value: 'ape', label: 'SQ 无损 / APE'),
    ];
  }
  if (context.providerId == 'kugou') {
    return const <SettingsChoice>[
      SettingsChoice(value: 'standard', label: '标准'),
      SettingsChoice(value: 'exhigh', label: 'HQ 高品音质'),
      SettingsChoice(value: 'lossless', label: 'SQ 无损音质'),
      SettingsChoice(value: 'hires', label: 'Hi-Res 高解析音质'),
    ];
  }
  if (context.providerId == 'siren') {
    return const <SettingsChoice>[
      SettingsChoice(value: 'lossless', label: '官网原始音源'),
    ];
  }
  if (context.providerId == 'local') {
    return const <SettingsChoice>[];
  }
  return const <SettingsChoice>[
    SettingsChoice(value: 'standard', label: '标准'),
    SettingsChoice(value: 'higher', label: '较高'),
    SettingsChoice(value: 'exhigh', label: '极高'),
    SettingsChoice(value: 'lossless', label: 'SQ 无损'),
    SettingsChoice(value: 'hires', label: 'Hi-Res 高解析音质'),
    SettingsChoice(value: 'jymaster', label: '超清母带'),
  ];
}

List<SettingsChoice> settingsGraphicsChoices(SettingsPreferenceContext context) {
  if (context.isDarwin) {
    return const <SettingsChoice>[
      SettingsChoice(value: 'metal', label: 'Metal'),
    ];
  }
  return <SettingsChoice>[
    const SettingsChoice(value: '', label: '默认 / 自动探测'),
    const SettingsChoice(value: 'vulkan', label: 'Vulkan'),
    const SettingsChoice(value: 'opengl', label: 'OpenGL'),
    if (context.direct3d12Available) const SettingsChoice(value: 'd3d12', label: 'Direct3D 12'),
  ];
}

List<SettingsChoice> settingsGpuChoices(SettingsPreferenceContext context) {
  final List<SettingsChoice> out = <SettingsChoice>[
    const SettingsChoice(value: '', label: '默认'),
  ];
  for (int index = 0; index < context.gpuDeviceCount; index++) {
    out.add(SettingsChoice(value: index.toString(), label: '显卡 $index'));
  }
  return out;
}

List<SettingsChoice> settingsAaChoices(SettingsPreferenceContext context) {
  if (context.isDarwin) {
    return const <SettingsChoice>[
      SettingsChoice(value: 'off', label: '关闭'),
      SettingsChoice(value: 'metalfx', label: 'MetalFX Temporal'),
    ];
  }
  return const <SettingsChoice>[
    SettingsChoice(value: 'off', label: '关闭'),
    SettingsChoice(value: 'fxaa', label: 'FXAA'),
    SettingsChoice(value: 'ssaa', label: 'SSAA'),
    SettingsChoice(value: 'msaa', label: 'MSAA'),
    SettingsChoice(value: 'taa', label: 'TAA'),
    SettingsChoice(value: 'fsr', label: 'FSR'),
  ];
}

/// SettingsSchema.cpp:36-94 的标签函数。choiceLabel 的统一兜底在
/// settingsChoiceLabel() 里，这些函数只处理有专名的几条。
String settingsThemeLabel(SettingsPreferenceContext context, SettingsPreferenceValue value) {
  for (final SettingsChoice choice in settingsThemeChoices) {
    if (choice.value == value.canonical) {
      return choice.label;
    }
  }
  return value.canonical;
}

String settingsArchiveMaskLabel(SettingsPreferenceContext context, SettingsPreferenceValue value) =>
    value.integer == 0 ? '0 · 关闭' : '${value.integer}%';

String settingsRenderScaleLabel(SettingsPreferenceContext context, SettingsPreferenceValue value) =>
    value.integer == 100 ? '100% · 原生' : '${value.integer}%';

String settingsPercentLabel(SettingsPreferenceContext context, SettingsPreferenceValue value) =>
    '${value.integer}%';

String settingsMsaaLabel(SettingsPreferenceContext context, SettingsPreferenceValue value) =>
    '${value.integer}x';

String settingsGraphicsBackendLabel(SettingsPreferenceContext context, SettingsPreferenceValue value) {
  if (context.isDarwin) {
    return 'Metal';
  }
  final Map<String, String> names = <String, String>{
    'vulkan': 'Vulkan',
    'opengl': 'OpenGL',
    'd3d12': 'Direct3D 12',
  };
  final String saved = value.raw;
  final String pending = saved.isEmpty ? '默认 / 自动探测' : (names[saved] ?? saved);
  final String applied = context.appliedGraphicsBackend;
  if (applied.isEmpty) {
    return pending;
  }
  final String appliedName = names[applied] ?? applied;
  if (saved.isEmpty) {
    return '$appliedName（自动）';
  }
  if (applied != saved) {
    return '$appliedName（下次启动：$pending）';
  }
  return appliedName;
}

String settingsGpuIndexLabel(SettingsPreferenceContext context, SettingsPreferenceValue value) {
  final String saved = value.raw.trim();
  final int? index = int.tryParse(saved);
  if (index != null && index >= 0 && index < context.gpuDeviceCount) {
    return '显卡 $index';
  }
  if (saved.isNotEmpty) {
    return '默认（序号 $saved 不存在）';
  }
  if (context.gpuAppliedIndex >= 0) {
    return '显卡 ${context.gpuAppliedIndex}（RHINE_GPU_INDEX）';
  }
  return '默认';
}

String settingsAaModeLabel(SettingsPreferenceContext context, SettingsPreferenceValue value) {
  if (context.isDarwin && !context.temporalAntialiasingAvailable) {
    return '系统或设备不支持';
  }
  for (final SettingsChoice choice in settingsAaChoices(context)) {
    if (choice.value == value.canonical) {
      return choice.label;
    }
  }
  return value.canonical;
}

String settingsFgLabel(SettingsPreferenceContext context, SettingsPreferenceValue value) =>
    context.frameGenerationLabel;

/// SettingsSchema.cpp:86-94 choiceLabel()：descriptor.label 优先，其次静态选项，
/// 最后回退 canonical。
String settingsChoiceLabel(
    SettingsDescriptor descriptor, SettingsPreferenceContext context, SettingsPreferenceValue value) {
  final SettingsLabelResolver? resolver = descriptor.label;
  if (resolver != null) {
    return resolver(context, value);
  }
  for (final SettingsChoice choice in settingsChoicesFor(descriptor, context)) {
    if (choice.value == value.canonical) {
      return choice.label;
    }
  }
  return value.canonical;
}

// 9.4 descriptor 表：23 条偏好（SettingsSchema.cpp:352-687）+ 8 条项目链接
//     （:664-687）。顺序即 Qt 的 add() 调用顺序。

final List<SettingsDescriptor> _settingsDescriptorTable = <SettingsDescriptor>[
  SettingsDescriptor(
    id: 'window',
    section: SettingsSectionId.preferences,
    kind: SettingsRowKind.action,
    bindingKind: SettingsBindingKind.action,
    order: 100,
    titleEn: 'WINDOW',
    titleZh: '窗口显示',
    actionLabel: '切换全屏 / F11',
    action: 'window:fullscreen',
    visible: settingsDesktopWindowVisible,
  ),
  SettingsDescriptor(
    id: 'close-behavior',
    section: SettingsSectionId.preferences,
    kind: SettingsRowKind.choice,
    storage: SettingsStorageType.trayQuit,
    order: 110,
    titleEn: 'CLOSE WINDOW',
    titleZh: '点击关闭窗口',
    defaultValue: 'quit',
    preferenceKey: 'close-behavior',
    action: 'close-behavior',
    actionPrefix: 'setting:close-behavior:',
    choices: settingsTrayQuitChoices,
    visible: settingsCloseVisible,
  ),
  SettingsDescriptor(
    id: 'theme',
    section: SettingsSectionId.preferences,
    kind: SettingsRowKind.choice,
    bindingKind: SettingsBindingKind.hudState,
    storage: SettingsStorageType.theme,
    order: 120,
    titleEn: 'COLOR THEME',
    titleZh: '界面配色',
    defaultValue: 'light',
    action: 'theme',
    actionPrefix: 'setting:theme:',
    choices: settingsThemeChoices,
    label: settingsThemeLabel,
  ),
  SettingsDescriptor(
    id: 'motion',
    section: SettingsSectionId.preferences,
    kind: SettingsRowKind.choice,
    bindingKind: SettingsBindingKind.hudState,
    storage: SettingsStorageType.reducedFull,
    order: 130,
    titleEn: 'REDUCED MOTION',
    titleZh: '动态效果',
    defaultValue: 'full',
    action: 'motion',
    actionPrefix: 'setting:motion:',
    choices: settingsMotionChoices,
  ),
  SettingsDescriptor(
    id: 'startup-animation',
    section: SettingsSectionId.preferences,
    kind: SettingsRowKind.choice,
    bindingKind: SettingsBindingKind.hudState,
    storage: SettingsStorageType.onOff,
    order: 140,
    titleEn: 'STARTUP ANIMATION',
    titleZh: '初始化动画',
    defaultValue: 'off',
    action: 'startup-animation',
    actionPrefix: 'setting:startup-animation:',
    choices: settingsOnOffChoices,
  ),
  SettingsDescriptor(
    id: 'replay',
    section: SettingsSectionId.preferences,
    kind: SettingsRowKind.action,
    bindingKind: SettingsBindingKind.action,
    order: 150,
    titleEn: 'INITIALIZATION',
    titleZh: '手动显示初始化页面',
    actionLabel: 'Reinitialize',
    action: 'replay',
  ),
  SettingsDescriptor(
    id: 'quality',
    section: SettingsSectionId.preferences,
    kind: SettingsRowKind.choice,
    bindingKind: SettingsBindingKind.player,
    storage: SettingsStorageType.playerQuality,
    order: 160,
    titleEn: 'AUDIO QUALITY',
    titleZh: '音质',
    defaultValue: 'exhigh',
    action: 'quality',
    actionPrefix: 'quality:set:',
    choicesFor: settingsQualityChoices,
    visible: settingsQualityVisible,
  ),
  SettingsDescriptor(
    id: 'alternative',
    section: SettingsSectionId.preferences,
    kind: SettingsRowKind.choice,
    bindingKind: SettingsBindingKind.player,
    storage: SettingsStorageType.playerAlternative,
    order: 170,
    titleEn: 'ALTERNATE SOURCE',
    titleZh: '替代音源',
    defaultValue: 'off',
    action: 'alternative',
    actionPrefix: 'setting:alternative:',
    choices: settingsAlternativeChoices,
    visible: settingsAlternativeVisible,
  ),
  SettingsDescriptor(
    id: 'official-player',
    section: SettingsSectionId.preferences,
    kind: SettingsRowKind.choice,
    bindingKind: SettingsBindingKind.external,
    storage: SettingsStorageType.externalBool,
    order: 180,
    titleEn: 'OFFICIAL PLAYER',
    titleZh: '官方窗口',
    defaultValue: 'off',
    action: 'music:activate',
    actionPrefix: 'setting:official-player:',
    choices: const <SettingsChoice>[
      SettingsChoice(value: 'off', label: '尽量保持后台'),
      SettingsChoice(value: 'on', label: '播放时显示'),
    ],
    visible: settingsOfficialPlayerVisible,
  ),
  SettingsDescriptor(
    id: 'detail-autoplay',
    section: SettingsSectionId.preferences,
    kind: SettingsRowKind.choice,
    storage: SettingsStorageType.onOff,
    order: 190,
    titleEn: 'ENTER AUTOPLAY',
    titleZh: '进入详情自动播放',
    defaultValue: 'off',
    preferenceKey: 'detail-autoplay',
    action: 'detail-autoplay',
    actionPrefix: 'setting:detail-autoplay:',
    choices: settingsOnOffChoices,
  ),
  SettingsDescriptor(
    id: 'single-play-mode',
    section: SettingsSectionId.preferences,
    kind: SettingsRowKind.choice,
    storage: SettingsStorageType.appendReplace,
    order: 200,
    titleEn: 'PLAYLIST ON PLAY',
    titleZh: '点击播放单曲',
    defaultValue: 'replace',
    preferenceKey: 'single-play-mode',
    action: 'single-play-mode',
    actionPrefix: 'setting:single-play-mode:',
    choices: settingsAppendReplaceChoices,
  ),
  SettingsDescriptor(
    id: 'desktop-lyrics',
    section: SettingsSectionId.preferences,
    kind: SettingsRowKind.action,
    bindingKind: SettingsBindingKind.action,
    order: 205,
    titleEn: 'DESKTOP LYRICS',
    titleZh: '桌面歌词',
    actionLabel: '样式与同步',
    action: 'desktop-lyrics:open',
    visible: settingsDesktopLyricsVisible,
  ),
  SettingsDescriptor(
    id: 'archive-mask',
    section: SettingsSectionId.preferences,
    kind: SettingsRowKind.stepper,
    bindingKind: SettingsBindingKind.hudState,
    storage: SettingsStorageType.hudCachedInt,
    order: 210,
    titleEn: 'RIGHT MASK',
    titleZh: '右侧画面遮罩',
    defaultValue: '50',
    minimum: 0,
    maximum: 100,
    step: 10,
    actionPrefix: 'archive-mask:',
    label: settingsArchiveMaskLabel,
  ),
  SettingsDescriptor(
    id: 'graphics-backend',
    section: SettingsSectionId.preferences,
    kind: SettingsRowKind.choice,
    storage: SettingsStorageType.enumeration,
    order: 220,
    titleEn: 'GRAPHICS BACKEND',
    titleZh: '图形后端',
    darwinTitleEn: 'METAL RENDERER',
    darwinTitleZh: '渲染模式',
    restartHint: '重启生效',
    darwinRestartHint: '',
    preferenceKey: 'graphics-backend',
    action: 'graphics-backend',
    actionPrefix: 'setting:graphics-backend:',
    choicesFor: settingsGraphicsChoices,
    enabled: settingsGraphicsEnabled,
    label: settingsGraphicsBackendLabel,
  ),
  SettingsDescriptor(
    id: 'gpu-index',
    section: SettingsSectionId.preferences,
    kind: SettingsRowKind.choice,
    storage: SettingsStorageType.enumeration,
    order: 230,
    titleEn: 'GPU',
    titleZh: '显卡',
    restartHint: '重启生效',
    preferenceKey: 'gpu-index',
    actionPrefix: 'gpu-index:',
    choicesFor: settingsGpuChoices,
    visible: settingsGpuVisible,
    label: settingsGpuIndexLabel,
  ),
  SettingsDescriptor(
    id: 'vsync',
    section: SettingsSectionId.preferences,
    kind: SettingsRowKind.choice,
    bindingKind: SettingsBindingKind.hudState,
    storage: SettingsStorageType.hudCachedBool,
    order: 240,
    titleEn: 'V-SYNC',
    titleZh: '垂直同步',
    restartHint: '重启生效',
    defaultValue: 'on',
    action: 'vsync',
    actionPrefix: 'setting:vsync:',
    choices: settingsOnOffChoices,
    visible: settingsVsyncVisible,
  ),
  SettingsDescriptor(
    id: 'render-scale',
    section: SettingsSectionId.preferences,
    kind: SettingsRowKind.stepper,
    storage: SettingsStorageType.integer,
    order: 250,
    titleEn: 'RENDER SCALE',
    titleZh: '渲染分辨率',
    // Qt/src/SettingsSchema.cpp:566 的 .defaultValue 是 androidDefaultRenderScale() 的字符串：
    // 桌面 / iOS 为 100，Android 为 75。这里保留 '100' 只是字面基线——validateRegistry()
    // 要求默认值落在 steps 内；平台相关默认统一由 settingsDefaultValue() 覆盖，
    // 读取、canonical 与恢复默认三条路径都经它，不会直接消费本字段。
    defaultValue: '100',
    preferenceKey: 'render-scale',
    actionPrefix: 'render-scale:',
    steps: const <int>[50, 60, 75, 90, 100],
    label: settingsRenderScaleLabel,
  ),
  SettingsDescriptor(
    id: 'aa-mode',
    section: SettingsSectionId.preferences,
    kind: SettingsRowKind.choice,
    storage: SettingsStorageType.enumeration,
    order: 260,
    titleEn: 'AA & UPSCALING',
    titleZh: '抗锯齿与超分辨率',
    darwinTitleEn: 'METALFX',
    darwinTitleZh: '时域抗锯齿与超分辨率',
    defaultValue: 'off',
    preferenceKey: 'aa-mode',
    actionPrefix: 'aa-mode:',
    choicesFor: settingsAaChoices,
    enabled: settingsAaEnabled,
    label: settingsAaModeLabel,
  ),
  SettingsDescriptor(
    id: 'aa-scale',
    section: SettingsSectionId.preferences,
    kind: SettingsRowKind.stepper,
    storage: SettingsStorageType.integer,
    order: 270,
    titleEn: 'AA SCALE',
    titleZh: '抗锯齿倍率',
    defaultValue: '125',
    minimum: 100,
    maximum: 200,
    step: 25,
    preferenceKey: 'aa-scale',
    actionPrefix: 'aa-scale:',
    visible: settingsAaScaleVisible,
    label: settingsPercentLabel,
  ),
  SettingsDescriptor(
    id: 'msaa',
    section: SettingsSectionId.preferences,
    kind: SettingsRowKind.stepper,
    storage: SettingsStorageType.integer,
    order: 280,
    titleEn: 'MSAA SAMPLES',
    titleZh: '多重采样倍率',
    defaultValue: '4',
    preferenceKey: 'msaa',
    actionPrefix: 'msaa:',
    steps: const <int>[2, 4, 8],
    wrap: true,
    visible: settingsMsaaVisible,
    label: settingsMsaaLabel,
  ),
  SettingsDescriptor(
    id: 'fsr-quality',
    section: SettingsSectionId.preferences,
    kind: SettingsRowKind.choice,
    storage: SettingsStorageType.enumeration,
    order: 290,
    titleEn: 'FSR QUALITY',
    titleZh: 'FSR 档位',
    defaultValue: 'native',
    preferenceKey: 'fsr-quality',
    actionPrefix: 'fsr-quality:',
    choices: settingsFsrChoices,
    visible: settingsFsrVisible,
  ),
  SettingsDescriptor(
    id: 'fsr-sharpness',
    section: SettingsSectionId.preferences,
    kind: SettingsRowKind.stepper,
    storage: SettingsStorageType.integer,
    order: 300,
    titleEn: 'FSR SHARPNESS',
    titleZh: 'FSR 锐化',
    defaultValue: '50',
    minimum: 0,
    maximum: 100,
    step: 10,
    preferenceKey: 'fsr-sharpness',
    actionPrefix: 'fsr-sharpness:',
    visible: settingsFsrVisible,
    label: settingsPercentLabel,
  ),
  SettingsDescriptor(
    id: 'fg',
    section: SettingsSectionId.preferences,
    kind: SettingsRowKind.choice,
    storage: SettingsStorageType.onOff,
    order: 310,
    titleEn: 'FRAME GENERATION',
    titleZh: '帧生成',
    defaultValue: 'off',
    preferenceKey: 'fg',
    action: 'fg',
    actionPrefix: 'setting:fg:',
    choices: settingsOnOffChoices,
    visible: settingsFgVisible,
    enabled: settingsFgEnabled,
    label: settingsFgLabel,
  ),
  SettingsDescriptor(
    id: 'project-home',
    section: SettingsSectionId.project,
    kind: SettingsRowKind.link,
    bindingKind: SettingsBindingKind.action,
    order: 10,
    titleEn: '本项目 / Rhine Music Database',
    titleZh: '本项目 / Rhine Music Database',
    actionLabel: '本项目 / Rhine Music Database',
    action: 'music:project-home',
  ),
  SettingsDescriptor(
    id: 'project-author',
    section: SettingsSectionId.project,
    kind: SettingsRowKind.link,
    bindingKind: SettingsBindingKind.action,
    order: 11,
    titleEn: '网易云音乐 API / api-enhanced',
    titleZh: '网易云音乐 API / api-enhanced',
    actionLabel: '网易云音乐 API / api-enhanced',
    action: 'music:project-author',
  ),
  SettingsDescriptor(
    id: 'project-player',
    section: SettingsSectionId.project,
    kind: SettingsRowKind.link,
    bindingKind: SettingsBindingKind.action,
    order: 12,
    titleEn: 'QQ 音乐 API / qq-music-api',
    titleZh: 'QQ 音乐 API / qq-music-api',
    actionLabel: 'QQ 音乐 API / qq-music-api',
    action: 'music:project-player',
  ),
  SettingsDescriptor(
    id: 'project-kugou',
    section: SettingsSectionId.project,
    kind: SettingsRowKind.link,
    bindingKind: SettingsBindingKind.action,
    order: 13,
    titleEn: '酷狗音乐 API / KuGouMusicApi',
    titleZh: '酷狗音乐 API / KuGouMusicApi',
    actionLabel: '酷狗音乐 API / KuGouMusicApi',
    action: 'music:project-kugou',
  ),
  SettingsDescriptor(
    id: 'project-rhine',
    section: SettingsSectionId.project,
    kind: SettingsRowKind.link,
    bindingKind: SettingsBindingKind.action,
    order: 14,
    titleEn: '界面原项目 / RhineLabUI',
    titleZh: '界面原项目 / RhineLabUI',
    actionLabel: '界面原项目 / RhineLabUI',
    action: 'music:project-rhine',
  ),
  SettingsDescriptor(
    id: 'project-lyricsx',
    section: SettingsSectionId.project,
    kind: SettingsRowKind.link,
    bindingKind: SettingsBindingKind.action,
    order: 15,
    titleEn: '歌词参考 / LyricsX',
    titleZh: '歌词参考 / LyricsX',
    actionLabel: '歌词参考 / LyricsX',
    action: 'music:project-lyricsx',
  ),
  SettingsDescriptor(
    id: 'project-lyricskit',
    section: SettingsSectionId.project,
    kind: SettingsRowKind.link,
    bindingKind: SettingsBindingKind.action,
    order: 16,
    titleEn: '格式移植 / LyricsKit',
    titleZh: '格式移植 / LyricsKit',
    actionLabel: '格式移植 / LyricsKit',
    action: 'music:project-lyricskit',
  ),
  SettingsDescriptor(
    id: 'project-lyrimuse',
    section: SettingsSectionId.project,
    kind: SettingsRowKind.link,
    bindingKind: SettingsBindingKind.action,
    order: 17,
    titleEn: '同步与匹配参考 / Lyrimuse',
    titleZh: '同步与匹配参考 / Lyrimuse',
    actionLabel: '同步与匹配参考 / Lyrimuse',
    action: 'music:project-lyrimuse',
  ),
];

/// 注册表的只读视图（Qt SettingsSchema::descriptors()）。
List<SettingsDescriptor> settingsDescriptors() =>
    List<SettingsDescriptor>.unmodifiable(_settingsDescriptorTable);

SettingsDescriptor? settingsDescriptorById(String id) {
  for (final SettingsDescriptor descriptor in _settingsDescriptorTable) {
    if (descriptor.id == id) {
      return descriptor;
    }
  }
  return null;
}

/// SettingsSchema::sections() + descriptors() 的分组：按 order 升序。
List<SettingsDescriptor> settingsSectionDescriptors(SettingsSectionId section) {
  final List<SettingsDescriptor> out = <SettingsDescriptor>[
    for (final SettingsDescriptor descriptor in _settingsDescriptorTable)
      if (descriptor.section == section) descriptor,
  ];
  out.sort((SettingsDescriptor a, SettingsDescriptor b) => a.order.compareTo(b.order));
  return out;
}

String settingsTitleEn(SettingsDescriptor descriptor, SettingsPreferenceContext context) =>
    context.isDarwin && descriptor.darwinTitleEn.isNotEmpty
        ? descriptor.darwinTitleEn
        : descriptor.titleEn;

String settingsTitleZh(SettingsDescriptor descriptor, SettingsPreferenceContext context) =>
    context.isDarwin && descriptor.darwinTitleZh.isNotEmpty
        ? descriptor.darwinTitleZh
        : descriptor.titleZh;

String settingsRestartHint(SettingsDescriptor descriptor, SettingsPreferenceContext context) =>
    context.isDarwin ? descriptor.darwinRestartHint : descriptor.restartHint;

/// render-scale 的默认值随平台，唯一真值在 Qt：
///
/// Qt/src/SettingsSchema.cpp:555-568 的 .defaultValue =
/// QString::number(RhineRender::androidDefaultRenderScale())；
/// Qt/src/render/AndroidRenderPolicy.h:95-116 的 androidDefaultRenderScale() 在
/// Q_OS_ANDROID 下：总开关关闭（RHINE_ANDROID_RENDER_TUNING=0）→ 100；
/// RHINE_ANDROID_RENDER_SCALE 落在 50..100 → 该值；否则 → 75。非 Android 恒为 100。
/// 所以 Android 的有效默认是 75，不是 90。
///
/// 两处「90%」注释都是 75 之前的残留、不是取值依据：SettingsSchema.cpp:565
/// （「Android 90%，其它平台 100%」）与 Qt/src/main.cpp:805-806
/// （「Android 取 90%」，:807-808 取的是同一个函数）。
///
/// Dart 宿主目前没有 RHINE_ANDROID_RENDER_TUNING / RHINE_ANDROID_RENDER_SCALE 的注入缝，
/// 因此这里只编码「无运行时覆盖」时的默认值，不伪造环境变量读取或平台通道。
/// 恢复默认走 NativeHudSettings.cpp:495-509 的同一条 descriptor.defaultValue 路径
/// （Dart 侧 settingsDefaultsResetPlan() 经 settingsNormalizeValue + 本函数），
/// 所以 Android 的「恢复默认」同样回到 75。
String settingsDefaultValue(SettingsDescriptor descriptor, SettingsPreferenceContext context) {
  if (descriptor.id == 'render-scale') {
    return context.operatingSystem == SettingsOperatingSystem.android ? '75' : '100';
  }
  return descriptor.defaultValue;
}

// 9.5 SettingsSchema 的纯函数：choices / normalize / read / displayLabel /
//     visible / enabled / switchTarget / nextValue / numericValues。

List<SettingsChoice> settingsChoicesFor(
        SettingsDescriptor descriptor, SettingsPreferenceContext context) =>
    descriptor.choicesFor?.call(context) ?? descriptor.choices;

/// SettingsSchema.cpp:441-452 nearestStep()：绝对距离最近，平局取先出现者。
int settingsNearestStep(List<int> steps, int value) {
  if (steps.isEmpty) {
    return value;
  }
  int best = steps.first;
  for (final int step in steps) {
    if ((step - value).abs() < (best - value).abs()) {
      best = step;
    }
  }
  return best;
}

String settingsNormalizeValue(
    SettingsDescriptor descriptor, SettingsPreferenceContext context, String raw) {
  final List<SettingsChoice> options = settingsChoicesFor(descriptor, context);
  final String fallback = settingsDefaultValue(descriptor, context);
  final String firstChoice = options.isEmpty ? '' : options.first.value;

  bool hasChoice(String value) {
    for (final SettingsChoice choice in options) {
      if (choice.value == value) {
        return true;
      }
    }
    return false;
  }

  switch (descriptor.storage) {
    case SettingsStorageType.onOff:
      return raw == 'on' || raw == 'off' ? raw : (fallback.isEmpty ? 'off' : fallback);
    case SettingsStorageType.reducedFull:
      return raw == 'reduced' || raw == 'full' ? raw : (fallback.isEmpty ? 'full' : fallback);
    case SettingsStorageType.theme:
      return raw == 'light' || raw == 'dark' || raw == 'system'
          ? raw
          : (fallback.isEmpty ? 'light' : fallback);
    case SettingsStorageType.trayQuit:
      return raw == 'tray' || raw == 'quit' ? raw : (fallback.isEmpty ? 'quit' : fallback);
    case SettingsStorageType.appendReplace:
      return raw == 'append' || raw == 'replace' ? raw : (fallback.isEmpty ? 'replace' : fallback);
    case SettingsStorageType.playerQuality:
      return hasChoice(raw) ? raw : (hasChoice(fallback) ? fallback : firstChoice);
    case SettingsStorageType.playerAlternative:
    case SettingsStorageType.externalBool:
    case SettingsStorageType.hudCachedBool:
    case SettingsStorageType.capability:
    case SettingsStorageType.updater:
      return raw == 'on' || raw == 'off' ? raw : (fallback.isEmpty ? 'off' : fallback);
    case SettingsStorageType.integer:
    case SettingsStorageType.hudCachedInt:
      final int value = int.tryParse(raw) ?? int.tryParse(fallback) ?? descriptor.minimum;
      if (descriptor.steps.isNotEmpty) {
        return settingsNearestStep(descriptor.steps, value).toString();
      }
      final int low = descriptor.minimum;
      final int high = descriptor.maximum < low ? low : descriptor.maximum;
      return value.clamp(low, high).toString();
    case SettingsStorageType.enumeration:
      if (descriptor.id == 'aa-mode' && (raw == 'fsr1' || raw == 'fsr3')) {
        return 'fsr';
      }
      if (descriptor.id == 'graphics-backend' && raw == 'd3d11') {
        return '';
      }
      return hasChoice(raw) ? raw : (hasChoice(fallback) ? fallback : firstChoice);
    case SettingsStorageType.none:
      return raw.isEmpty ? fallback : raw;
  }
}

SettingsPreferenceValue settingsReadPreference(
  SettingsDescriptor descriptor, {
  required SettingsPreferenceContext context,
  required SettingsPreferenceSnapshot snapshot,
}) {
  String raw = '';
  switch (descriptor.bindingKind) {
    case SettingsBindingKind.preference:
      raw = snapshot.preference(descriptor.preferenceKey);
      break;
    case SettingsBindingKind.hudState:
      switch (descriptor.storage) {
        case SettingsStorageType.theme:
          raw = snapshot.themeMode;
          break;
        case SettingsStorageType.reducedFull:
          raw = snapshot.reducedMotion ? 'reduced' : 'full';
          break;
        case SettingsStorageType.hudCachedInt:
          raw = snapshot.archiveMaskStrength.toString();
          break;
        default:
          if (descriptor.id == 'startup-animation') {
            raw = snapshot.startupAnimation ? 'on' : 'off';
          } else if (descriptor.id == 'vsync') {
            raw = snapshot.vsync ? 'on' : 'off';
          } else {
            raw = '';
          }
      }
      break;
    case SettingsBindingKind.player:
      raw = descriptor.id == 'quality' ? snapshot.quality : (snapshot.alternative ? 'on' : 'off');
      break;
    case SettingsBindingKind.external:
      raw = snapshot.officialPlayerActive ? 'on' : 'off';
      break;
    case SettingsBindingKind.capability:
    case SettingsBindingKind.updater:
      raw = snapshot.preference(descriptor.preferenceKey);
      break;
    case SettingsBindingKind.action:
    case SettingsBindingKind.customSection:
      raw = '';
      break;
  }
  final String canonical = settingsNormalizeValue(descriptor, context, raw);
  final int? integer = int.tryParse(canonical);
  final bool boolean = canonical == 'on' ||
      canonical == 'reduced' ||
      canonical == 'tray' ||
      canonical == 'append';
  return SettingsPreferenceValue(
    raw: raw,
    canonical: canonical,
    integer: integer ?? 0,
    boolean: boolean,
    valid: integer != null || canonical.isNotEmpty,
    isDefault: raw.isEmpty,
  );
}

String settingsDisplayLabel(
    SettingsDescriptor descriptor, SettingsPreferenceContext context, SettingsPreferenceValue value) {
  if (descriptor.kind == SettingsRowKind.action || descriptor.kind == SettingsRowKind.link) {
    return descriptor.actionLabel;
  }
  return settingsChoiceLabel(descriptor, context, value);
}

bool settingsVisible(SettingsDescriptor descriptor, SettingsPreferenceContext context) =>
    descriptor.visible?.call(context) ?? true;

bool settingsEnabled(SettingsDescriptor descriptor, SettingsPreferenceContext context) =>
    descriptor.enabled?.call(context) ?? true;

/// SettingsSchema.cpp:293-330 switchTarget()：多于一个选项就循环到下一个，
/// 否则按 storage 做二元翻转。
String settingsSwitchTarget(
    SettingsDescriptor descriptor, SettingsPreferenceContext context, SettingsPreferenceValue value) {
  final List<SettingsChoice> options = settingsChoicesFor(descriptor, context);
  if (options.length >= 2) {
    int index = 0;
    for (int i = 0; i < options.length; i++) {
      if (options[i].value == value.canonical) {
        index = i;
        break;
      }
    }
    return options[(index + 1) % options.length].value;
  }
  switch (descriptor.storage) {
    case SettingsStorageType.reducedFull:
      return value.canonical == 'reduced' ? 'full' : 'reduced';
    case SettingsStorageType.trayQuit:
      return value.canonical == 'tray' ? 'quit' : 'tray';
    case SettingsStorageType.appendReplace:
      return value.canonical == 'append' ? 'replace' : 'append';
    default:
      return value.canonical == 'on' ? 'off' : 'on';
  }
}

/// NativeHudSettings.cpp:26-37 numericValues()。
List<int> settingsNumericValues(SettingsDescriptor descriptor) {
  if (descriptor.steps.isNotEmpty) {
    return descriptor.steps;
  }
  return <int>[
    if (descriptor.step > 0)
      for (int value = descriptor.minimum; value <= descriptor.maximum; value += descriptor.step) value,
  ];
}

/// SettingsSchema.cpp:332-360 nextValue()。
String settingsNextValue(
    SettingsDescriptor descriptor, SettingsPreferenceContext context, SettingsPreferenceValue value, int direction) {
  if (descriptor.kind == SettingsRowKind.choice) {
    final List<SettingsChoice> options = settingsChoicesFor(descriptor, context);
    if (options.isEmpty) {
      return value.canonical;
    }
    int index = 0;
    for (int i = 0; i < options.length; i++) {
      if (options[i].value == value.canonical) {
        index = i;
        break;
      }
    }
    final int target = (index + direction).clamp(0, options.length - 1).toInt();
    return options[target].value;
  }
  if (descriptor.kind == SettingsRowKind.stepper || descriptor.kind == SettingsRowKind.slider) {
    final List<int> numeric = settingsNumericValues(descriptor);
    if (numeric.isNotEmpty) {
      int index = 0;
      for (int i = 0; i < numeric.length; i++) {
        if (numeric[i] == value.integer) {
          index = i;
          break;
        }
      }
      int target;
      if (descriptor.wrap) {
        target = (index + direction + numeric.length) % numeric.length;
      } else {
        target = (index + direction).clamp(0, numeric.length - 1).toInt();
      }
      return numeric[target].toString();
    }
    final int step = descriptor.step > 0 ? descriptor.step : 1;
    final int moved = value.integer + direction * step;
    final int low = descriptor.minimum;
    final int high = descriptor.maximum < low ? low : descriptor.maximum;
    return moved.clamp(low, high).toString();
  }
  return value.canonical;
}

// 9.6 行模型组装（NativeHudSettings.cpp:39-77 buildSettingsModel）。

SettingsRowSpec settingsRowSpecFor(
  SettingsDescriptor descriptor, {
  required SettingsPreferenceContext context,
  required SettingsPreferenceSnapshot snapshot,
  String expandedId = '',
}) {
  final SettingsPreferenceValue value =
      settingsReadPreference(descriptor, context: context, snapshot: snapshot);
  final bool enabled = settingsEnabled(descriptor, context);
  return SettingsRowSpec(
    id: descriptor.id,
    kind: descriptor.kind,
    bindingKind: descriptor.bindingKind,
    action: descriptor.action,
    actionPrefix: descriptor.actionPrefix,
    preferenceKey: descriptor.preferenceKey,
    titleEn: settingsTitleEn(descriptor, context),
    titleZh: settingsTitleZh(descriptor, context),
    actionLabel: descriptor.actionLabel,
    restartHint: settingsRestartHint(descriptor, context),
    label: settingsDisplayLabel(descriptor, context, value),
    value: SettingsRowValue(canonical: value.canonical, integer: value.integer),
    choices: settingsChoicesFor(descriptor, context),
    numericValues: settingsNumericValues(descriptor),
    decrementValue: settingsNextValue(descriptor, context, value, -1),
    incrementValue: settingsNextValue(descriptor, context, value, 1),
    targetValue: settingsSwitchTarget(descriptor, context, value),
    enabled: enabled,
    expanded: expandedId == descriptor.id && enabled,
  );
}

/// 真注册表驱动的七区模型：自定义区没有行，Preferences / Project 走 descriptor。
List<SettingsSectionModel> settingsSectionModels({
  SettingsPreferenceContext context = const SettingsPreferenceContext(),
  SettingsPreferenceSnapshot snapshot = const SettingsPreferenceSnapshot(),
  String expandedId = '',
}) {
  final List<SettingsSectionModel> out = <SettingsSectionModel>[];
  for (final SettingsSectionSpec spec in orderedSettingsSections()) {
    if (!settingsSectionVisible(spec, context.capabilities)) {
      continue;
    }
    if (spec.hasCustomRenderer) {
      out.add(SettingsSectionModel(spec: spec));
      continue;
    }
    final List<SettingsRowSpec> rows = <SettingsRowSpec>[];
    for (final SettingsDescriptor descriptor in settingsSectionDescriptors(spec.id)) {
      if (!settingsVisible(descriptor, context)) {
        continue;
      }
      rows.add(settingsRowSpecFor(descriptor,
          context: context, snapshot: snapshot, expandedId: expandedId));
    }
    out.add(SettingsSectionModel(spec: spec, rows: rows));
  }
  return out;
}

/// Project 区的 8 条链接行（SettingsSchema.cpp:664-687）。
List<SettingsRowSpec> settingsProjectRows({
  SettingsPreferenceContext context = const SettingsPreferenceContext(),
  SettingsPreferenceSnapshot snapshot = const SettingsPreferenceSnapshot(),
}) =>
    <SettingsRowSpec>[
      for (final SettingsDescriptor descriptor in settingsSectionDescriptors(SettingsSectionId.project))
        settingsRowSpecFor(descriptor, context: context, snapshot: snapshot),
    ];

// 9.7 SettingsSchema::validateRegistry()：与 settings_row 无关的静态自检。

List<String> settingsValidateRegistry() {
  final List<String> errors = <String>[];
  final Set<int> sectionIds = <int>{};
  for (final SettingsSectionSpec section in settingsSections) {
    if (!sectionIds.add(section.id.index)) {
      errors.add('重复的分区 id: ${section.id.index}');
    }
    if (section.titleEn.isEmpty || section.number <= 0) {
      errors.add('分区缺少标题或编号: ${section.titleEn}');
    }
  }
  final Set<String> ids = <String>{};
  final Set<String> actions = <String>{};
  for (final SettingsDescriptor descriptor in _settingsDescriptorTable) {
    if (descriptor.id.isEmpty || !ids.add(descriptor.id)) {
      errors.add('空或重复的 descriptor id: ${descriptor.id}');
    }
    if (settingsSectionById(descriptor.section) == null) {
      errors.add('${descriptor.id}: 引用了不存在的分区');
    }
    if (descriptor.titleEn.isEmpty) {
      errors.add('${descriptor.id}: 缺少标题');
    }
    if (descriptor.bindingKind == SettingsBindingKind.preference &&
        !isSettingsPreferenceKey(descriptor.preferenceKey)) {
      errors.add('${descriptor.id}: 偏好 key 不在 Host::preferenceKeys() 中: ${descriptor.preferenceKey}');
    }
    if (descriptor.kind == SettingsRowKind.action && descriptor.action.isEmpty) {
      errors.add('${descriptor.id}: Action 缺少 action');
    }
    if ((descriptor.kind == SettingsRowKind.choice ||
            descriptor.kind == SettingsRowKind.stepper ||
            descriptor.kind == SettingsRowKind.slider) &&
        descriptor.action.isEmpty &&
        descriptor.actionPrefix.isEmpty) {
      errors.add('${descriptor.id}: 可编辑控件缺少 action/actionPrefix');
    }
    final String actionKey = descriptor.actionPrefix.isEmpty ? descriptor.action : descriptor.actionPrefix;
    if (actionKey.isNotEmpty && !actions.add(actionKey)) {
      errors.add('${descriptor.id}: 重复的 action: $actionKey');
    }
    final Set<String> choiceValues = <String>{};
    for (final SettingsChoice choice in descriptor.choices) {
      if (choice.value.isEmpty || !choiceValues.add(choice.value)) {
        errors.add('${descriptor.id}: 选项值为空或重复: ${choice.value}');
      }
    }
    if (descriptor.choices.isNotEmpty &&
        descriptor.defaultValue.isNotEmpty &&
        !choiceValues.contains(descriptor.defaultValue)) {
      errors.add('${descriptor.id}: 默认值不在静态选项中: ${descriptor.defaultValue}');
    }
    if (descriptor.minimum > descriptor.maximum) {
      errors.add('${descriptor.id}: minimum 大于 maximum');
    }
    if (descriptor.step < 0) {
      errors.add('${descriptor.id}: step 为负数');
    }
    if (descriptor.steps.isNotEmpty) {
      for (int i = 1; i < descriptor.steps.length; i++) {
        if (descriptor.steps[i] <= descriptor.steps[i - 1]) {
          errors.add('${descriptor.id}: steps 未排序');
          break;
        }
      }
      final int? fallback = int.tryParse(descriptor.defaultValue);
      if (fallback != null && !descriptor.steps.contains(fallback)) {
        errors.add('${descriptor.id}: 默认值不在 steps 中');
      }
    }
  }
  return errors;
}

// 9.8 恢复默认设置（NativeHudSettings.cpp:492-525）的纯计划。

class SettingsDefaultResetStep {
  const SettingsDefaultResetStep({
    required this.id,
    required this.value,
    required this.outcome,
    this.preferenceKey = '',
    this.action = '',
  });

  final String id;
  final String value;
  final SettingsCommitOutcome outcome;
  final String preferenceKey;
  final String action;

  @override
  String toString() =>
      'SettingsDefaultResetStep($id, $value, $outcome)';
}

class SettingsDefaultsResetPlan {
  const SettingsDefaultsResetPlan({
    required this.steps,
    required this.resetsDiscRotation,
    required this.clearsAutoUpdate,
    required this.resetsDesktopLyrics,
    required this.status,
  });

  /// 逐 descriptor 的 applySettingValue(defaultValue)，顺序与 Qt 循环一致。
  final List<SettingsDefaultResetStep> steps;

  /// :509-511 discRotation 为真时派发一次 disc-rotation。
  final bool resetsDiscRotation;

  /// :512 无条件清掉 auto-update。
  final bool clearsAutoUpdate;

  /// :513-519 DesktopLyrics 平台：关闭并复位 11 个外观 key。
  final bool resetsDesktopLyrics;
  final String status;

  /// :520-521 与 :523。
  double get scroll => 0;
  bool get clearsExpandedPreference => true;

  static const String autoUpdatePreferenceKey = 'auto-update';
  static const String desktopLyricsEnabledKey = 'desktop-lyrics';
}

SettingsDefaultsResetPlan settingsDefaultsResetPlan({
  SettingsPreferenceContext context = const SettingsPreferenceContext(),
  SettingsPreferenceSnapshot snapshot = const SettingsPreferenceSnapshot(),
}) {
  final List<SettingsDefaultResetStep> steps = <SettingsDefaultResetStep>[];
  for (final SettingsDescriptor descriptor in _settingsDescriptorTable) {
    if (descriptor.kind == SettingsRowKind.action ||
        descriptor.kind == SettingsRowKind.link ||
        descriptor.kind == SettingsRowKind.custom) {
      continue;
    }
    if (descriptor.bindingKind == SettingsBindingKind.customSection) {
      continue;
    }
    if (!settingsVisible(descriptor, context)) {
      continue;
    }
    if (descriptor.id == 'gpu-index') {
      steps.add(const SettingsDefaultResetStep(
        id: 'gpu-index',
        value: '',
        outcome: SettingsCommitOutcome.applied,
        preferenceKey: 'gpu-index',
      ));
      continue;
    }
    final SettingsRowSpec row =
        settingsRowSpecFor(descriptor, context: context, snapshot: snapshot);
    final String target =
        settingsNormalizeValue(descriptor, context, settingsDefaultValue(descriptor, context));
    final SettingsApplyPlan plan = planSettingsApply(
      descriptor: row,
      target: target,
      currentCanonical: row.value.canonical,
      isDarwin: context.isDarwin,
    );
    steps.add(SettingsDefaultResetStep(
      id: descriptor.id,
      value: target,
      outcome: plan.outcome,
      preferenceKey: plan.preferenceKey ?? '',
      action: plan.action ?? '',
    ));
  }
  return SettingsDefaultsResetPlan(
    steps: List<SettingsDefaultResetStep>.unmodifiable(steps),
    resetsDiscRotation: snapshot.discRotation,
    clearsAutoUpdate: true,
    resetsDesktopLyrics: context.capabilities.desktopLyrics,
    status: '已恢复默认设置',
  );
}



