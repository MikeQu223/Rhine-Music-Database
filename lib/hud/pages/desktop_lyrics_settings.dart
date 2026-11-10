/// Qt 桌面歌词（DESKTOP LYRICS）模态的纯 Dart 迁移层：平台能力矩阵、12 个偏好键与
/// 默认值、取值规范化、动作分发、页面几何与绘制计划。
///
/// 唯一权威来源（逐条在注释里标 `文件:行号`，不凭记忆改写）：
/// - Qt/src/DesktopLyricsSettingsPage.cpp:15-31（页面常量与派生高度）、:38-58（两套调色板）、
///   :60-66（colorArray / action）、:70-75（measure）、:77-160（section/row/stepper/segments/palette）、
///   :162-303（五个 section、十二个带行号的行、SYNC 与 RESET 块）
/// - Qt/src/NativeHudDesktopLyrics.cpp:22-49（外观缓存与布局刷新）、:51-119（面板/视口/滚动条/滚动按钮）、
///   :121-219（desktop-lyrics: 前缀的动作分发与写入门控）
/// - Qt/src/NativeHudModal.cpp:26-77（模态标题与副标题）、:188-202（分类、返回按钮、标题排版）、
///   :243-254（面板分发）
/// - Qt/src/NativeHud.cpp:110-120（button：命中 + 底色 + 居中文本）
/// - Qt/src/NativeHud.h:126-127（DesktopLyricsViewportTop / Bottom）
/// - Qt/src/HudScroll.h:13-19,50-64,67-86（maximum / clampOffset / rail / clipHits）
/// - Qt/src/DesktopLyricsLayout.h:15-32（数值域与默认值）、:35-46（12 个键名）、:56-69（外观结构）
/// - Qt/src/DesktopLyricsAppearance.cpp:10-35（readInteger/readOutline/readColor/readWeight）、
///   :49-72（readAppearance）、:74-89（resetAppearance）、:91-101（isAppearanceKey）
/// - Qt/src/PlatformFeatures.h:7-24（移动端四特性 false；DesktopLyrics 仅 macOS/Windows）
/// - Qt/src/SettingsSchema.cpp:483-491（设置页入口：Action + 可见性 desktopLyricsVisible）
/// - Qt/src/NativeHudSettings.cpp:516-519（恢复默认：先写开关 off，再 resetAppearance）
///
/// 分层边界：本文件只产出「绘制计划 + 命中计划 + 几何」，不依赖 Flutter widget 层，
/// 也不做任何 I/O；颜色角色在 paint 阶段用 SettingsPalette 解析，命中裁剪复用
/// clipSettingsHits（等价 HudScroll::clipHits）。
///
/// 竖屏（portrait）在 Qt 没有像素基线，这里只做重排（控件宽度 / 列数），
/// 不新增任何 Qt 中不存在的像素常量，也不删除任何行。
library;

import 'dart:math' as math;
import 'dart:ui' show Rect;

import 'package:rhine_music_database/hud/widgets/settings_row.dart';

// ══════════════════════════════════════════════════════════════════════════════
// 1. 平台能力矩阵
// ══════════════════════════════════════════════════════════════════════════════

/// 平台标识，对应 Qt/src/PlatformFeatures.h:7-24 的编译期分支
/// （RHINE_MOBILE 与 Q_OS_MACOS / Q_OS_WIN）。
enum HudPlatform { android, ios, windows, macos, linux }

/// 平台特性快照，逐条对应 Qt/src/PlatformFeatures.h:9-24 的五个常量。
class HudCapabilities {
  const HudCapabilities({
    required this.officialPlayback,
    required this.localMusic,
    required this.applicationVolume,
    required this.desktopWindowControls,
    required this.desktopLyrics,
  });

  /// Qt/src/PlatformFeatures.h:9 / :14
  final bool officialPlayback;

  /// Qt/src/PlatformFeatures.h:10 / :15
  final bool localMusic;

  /// Qt/src/PlatformFeatures.h:11 / :16
  final bool applicationVolume;

  /// Qt/src/PlatformFeatures.h:12 / :17
  final bool desktopWindowControls;

  /// Qt/src/PlatformFeatures.h:20-24：只有 macOS / Windows 为 true。
  final bool desktopLyrics;

  /// 按平台推导（Qt/src/PlatformFeatures.h:7-24 的两个宏分支）。
  factory HudCapabilities.forPlatform(HudPlatform platform) {
    switch (platform) {
      case HudPlatform.android:
      case HudPlatform.ios:
        // Qt/src/PlatformFeatures.h:7-12：移动端四个特性一律 false。
        return HudCapabilities.android;
      case HudPlatform.windows:
        return HudCapabilities.windows;
      case HudPlatform.macos:
        return HudCapabilities.macos;
      case HudPlatform.linux:
        return HudCapabilities.linux;
    }
  }

  /// Qt/src/PlatformFeatures.h:9-12（RHINE_MOBILE 分支）。
  static const HudCapabilities android = HudCapabilities(
    officialPlayback: false,
    localMusic: false,
    applicationVolume: false,
    desktopWindowControls: false,
    desktopLyrics: false,
  );

  /// Qt/src/PlatformFeatures.h:9-12（RHINE_MOBILE 分支）。
  static const HudCapabilities ios = HudCapabilities(
    officialPlayback: false,
    localMusic: false,
    applicationVolume: false,
    desktopWindowControls: false,
    desktopLyrics: false,
  );

  /// Qt/src/PlatformFeatures.h:13-24（桌面端 + Q_OS_WIN）。
  static const HudCapabilities windows = HudCapabilities(
    officialPlayback: true,
    localMusic: true,
    applicationVolume: true,
    desktopWindowControls: true,
    desktopLyrics: true,
  );

  /// Qt/src/PlatformFeatures.h:13-24（桌面端 + Q_OS_MACOS）。
  static const HudCapabilities macos = HudCapabilities(
    officialPlayback: true,
    localMusic: true,
    applicationVolume: true,
    desktopWindowControls: true,
    desktopLyrics: true,
  );

  /// Qt/src/PlatformFeatures.h:13-18,22-23：桌面端但没有悬浮歌词。
  static const HudCapabilities linux = HudCapabilities(
    officialPlayback: true,
    localMusic: true,
    applicationVolume: true,
    desktopWindowControls: true,
    desktopLyrics: false,
  );

  @override
  bool operator ==(Object other) =>
      other is HudCapabilities &&
      other.officialPlayback == officialPlayback &&
      other.localMusic == localMusic &&
      other.applicationVolume == applicationVolume &&
      other.desktopWindowControls == desktopWindowControls &&
      other.desktopLyrics == desktopLyrics;

  @override
  int get hashCode => Object.hash(officialPlayback, localMusic, applicationVolume,
      desktopWindowControls, desktopLyrics);

  @override
  String toString() => 'HudCapabilities(desktopLyrics: ' + desktopLyrics.toString() + ')';
}

/// 设置页是否显示「DESKTOP LYRICS」入口。
///
/// Qt/src/SettingsSchema.cpp:483-491 的 `.visible = desktopLyricsVisible`，
/// 即 PlatformFeatures::DesktopLyrics；Android / iOS / Linux 一律不可见。
bool shouldShowDesktopLyricsEntry(HudCapabilities capabilities) => capabilities.desktopLyrics;

/// 是否允许页面存在并写入桌面歌词的 12 个键。
///
/// 写入门控本身在 Qt/src/NativeHudDesktopLyrics.cpp:146-217，但只有桌面歌词模态
/// 可被打开时才会被调用；模态入口又受 PlatformFeatures::DesktopLyrics 约束
/// （Qt/src/SettingsSchema.cpp:491），所以 Android / iOS / Linux 不写任何键。
bool desktopLyricsWritable(HudCapabilities capabilities) => capabilities.desktopLyrics;

/// 「恢复默认设置」是否触碰桌面歌词。
///
/// Qt/src/NativeHudSettings.cpp:516-519：`if (PlatformFeatures::DesktopLyrics)`
/// 才写开关 off + resetAppearance，并把外观缓存标记为未加载。
bool restoreShouldTouchDesktopLyrics(HudCapabilities capabilities) => capabilities.desktopLyrics;

// ══════════════════════════════════════════════════════════════════════════════
// 2. 12 个偏好键、数值域与默认值
// ══════════════════════════════════════════════════════════════════════════════

/// 12 个偏好键，逐字取自 Qt/src/DesktopLyricsLayout.h:35-46。
///
/// 键定义必须留在源码里：即使当前平台 desktopLyrics=false（Android / iOS / Linux），
/// 也不删除、不改名，恢复默认与偏好迁移仍按这张表工作。
class DesktopLyricsKeys {
  const DesktopLyricsKeys._();

  /// Qt/src/DesktopLyricsLayout.h:35
  static const String enabled = 'desktop-lyrics';

  /// Qt/src/DesktopLyricsLayout.h:36
  static const String lineSize = 'desktop-lyrics-size';

  /// Qt/src/DesktopLyricsLayout.h:37
  static const String translationSize = 'desktop-lyrics-translation-size';

  /// Qt/src/DesktopLyricsLayout.h:38
  static const String opacity = 'desktop-lyrics-opacity';

  /// Qt/src/DesktopLyricsLayout.h:39
  static const String lineColor = 'desktop-lyrics-line-color';

  /// Qt/src/DesktopLyricsLayout.h:40
  static const String translationColor = 'desktop-lyrics-translation-color';

  /// Qt/src/DesktopLyricsLayout.h:41
  static const String lineWeight = 'desktop-lyrics-line-weight';

  /// Qt/src/DesktopLyricsLayout.h:42
  static const String translationWeight = 'desktop-lyrics-translation-weight';

  /// Qt/src/DesktopLyricsLayout.h:43
  static const String lineOutline = 'desktop-lyrics-line-outline';

  /// Qt/src/DesktopLyricsLayout.h:44
  static const String translationOutline = 'desktop-lyrics-translation-outline';

  /// Qt/src/DesktopLyricsLayout.h:45
  static const String lineOutlineColor = 'desktop-lyrics-line-outline-color';

  /// Qt/src/DesktopLyricsLayout.h:46
  static const String translationOutlineColor = 'desktop-lyrics-translation-outline-color';

  /// 全部 12 个键，顺序同 Qt/src/DesktopLyricsLayout.h:35-46。
  static const List<String> all = <String>[
    enabled,
    lineSize,
    translationSize,
    opacity,
    lineColor,
    translationColor,
    lineWeight,
    translationWeight,
    lineOutline,
    translationOutline,
    lineOutlineColor,
    translationOutlineColor,
  ];
}

/// 数值域与默认值，逐字取自 Qt/src/DesktopLyricsLayout.h:15-32。
class DesktopLyricsDefaults {
  const DesktopLyricsDefaults._();

  /// Qt/src/DesktopLyricsLayout.h:15
  static const int minimumLineSize = 20;

  /// Qt/src/DesktopLyricsLayout.h:16
  static const int maximumLineSize = 60;

  /// Qt/src/DesktopLyricsLayout.h:17
  static const int lineSize = 32;

  /// Qt/src/DesktopLyricsLayout.h:18
  static const int minimumTranslationSize = 16;

  /// Qt/src/DesktopLyricsLayout.h:19
  static const int maximumTranslationSize = 48;

  /// Qt/src/DesktopLyricsLayout.h:20
  static const int translationSize = 24;

  /// Qt/src/DesktopLyricsLayout.h:21
  static const int minimumOpacity = 20;

  /// Qt/src/DesktopLyricsLayout.h:22
  static const int maximumOpacity = 100;

  /// Qt/src/DesktopLyricsLayout.h:23
  static const int opacity = 100;

  /// Qt/src/DesktopLyricsLayout.h:24
  static const double maximumOutline = 4;

  /// Qt/src/DesktopLyricsLayout.h:25
  static const double outlineStep = 0.5;

  /// Qt/src/DesktopLyricsLayout.h:26
  static const double lineOutline = 1.5;

  /// Qt/src/DesktopLyricsLayout.h:27
  static const double translationOutline = 1;

  /// Qt/src/DesktopLyricsLayout.h:28
  static const String lineColor = '#f5f6f2';

  /// Qt/src/DesktopLyricsLayout.h:29
  static const String translationColor = '#f5f6f2';

  /// Qt/src/DesktopLyricsLayout.h:30
  static const String outlineColor = '#000000';

  /// Qt/src/DesktopLyricsLayout.h:31
  static const String lineWeight = 'bold';

  /// Qt/src/DesktopLyricsLayout.h:32
  static const String translationWeight = 'regular';

  /// 开关的默认值：Qt/src/NativeHudDesktopLyrics.cpp:38 只有读到 "on" 才算开启，
  /// 缺省即 off；Qt/src/NativeHudSettings.cpp:517 恢复默认也写 off。
  static const String enabled = 'off';
}

/// 取值域，对应 Qt/src/DesktopLyricsAppearance.cpp:10-35 的四个读取器与
/// Qt/src/NativeHudDesktopLyrics.cpp:180-217 的四个写入门控。
enum DesktopLyricsValueDomain {
  /// 开关：只接受 "on" / 其它一律 "off"（Qt/src/NativeHudDesktopLyrics.cpp:181-183）。
  toggle,

  /// 整数：toInt 成功才写，clamp 到闭区间（Qt/src/NativeHudDesktopLyrics.cpp:150-155）。
  integer,

  /// 颜色：QColor 校验通过才写，写 name(HexRgb).toLower()
  /// （Qt/src/NativeHudDesktopLyrics.cpp:170-173）。
  color,

  /// 字重：白名单 light/regular/demibold/bold（Qt/src/NativeHudDesktopLyrics.cpp:175-177）。
  weight,

  /// 描边：toDouble 成功才写，clamp 0..4 后四舍五入到 0.5，序列化为一位小数
  /// （Qt/src/NativeHudDesktopLyrics.cpp:157-168）。
  outline,
}

/// 单个键的规格：键名、规范默认值、取值域、域参数、证据行号。
class DesktopLyricsKeySpec {
  const DesktopLyricsKeySpec({
    required this.key,
    required this.defaultValue,
    required this.domain,
    this.minimum,
    this.maximum,
    this.minimumOutline,
    this.maximumOutline,
    this.outlineStep,
    required this.source,
  });

  final String key;

  /// 规范形式（写入偏好时用的字符串，必须能被 normalizeDesktopLyricsValue 原样返回）。
  final String defaultValue;

  final DesktopLyricsValueDomain domain;

  /// 整数域闭区间；其它域为 null。
  final int? minimum;
  final int? maximum;

  /// 描边域闭区间与步长；其它域为 null。
  final double? minimumOutline;
  final double? maximumOutline;
  final double? outlineStep;

  /// 证据：Qt 文件:行号。
  final String source;

  @override
  bool operator ==(Object other) => other is DesktopLyricsKeySpec && other.key == key;

  @override
  int get hashCode => key.hashCode;

  @override
  String toString() => 'DesktopLyricsKeySpec(' + key + ' = ' + defaultValue + ')';
}

/// 12 键总表（Qt/src/DesktopLyricsLayout.h:15-46 + Qt/src/DesktopLyricsAppearance.cpp:49-72）。
const List<DesktopLyricsKeySpec> desktopLyricsKeyTable = <DesktopLyricsKeySpec>[
  DesktopLyricsKeySpec(
    key: DesktopLyricsKeys.enabled,
    defaultValue: 'off',
    domain: DesktopLyricsValueDomain.toggle,
    source: 'Qt/src/DesktopLyricsLayout.h:35（键）+ Qt/src/NativeHudDesktopLyrics.cpp:38'
        '（只有 "on" 算开启）+ Qt/src/NativeHudSettings.cpp:517（恢复默认写 off）',
  ),
  DesktopLyricsKeySpec(
    key: DesktopLyricsKeys.lineSize,
    defaultValue: '32',
    domain: DesktopLyricsValueDomain.integer,
    minimum: 20,
    maximum: 60,
    source: 'Qt/src/DesktopLyricsLayout.h:15-17 + Qt/src/DesktopLyricsAppearance.cpp:53',
  ),
  DesktopLyricsKeySpec(
    key: DesktopLyricsKeys.translationSize,
    defaultValue: '24',
    domain: DesktopLyricsValueDomain.integer,
    minimum: 16,
    maximum: 48,
    source: 'Qt/src/DesktopLyricsLayout.h:18-20 + Qt/src/DesktopLyricsAppearance.cpp:54',
  ),
  DesktopLyricsKeySpec(
    key: DesktopLyricsKeys.opacity,
    defaultValue: '100',
    domain: DesktopLyricsValueDomain.integer,
    minimum: 20,
    maximum: 100,
    source: 'Qt/src/DesktopLyricsLayout.h:21-23 + Qt/src/DesktopLyricsAppearance.cpp:55',
  ),
  DesktopLyricsKeySpec(
    key: DesktopLyricsKeys.lineColor,
    defaultValue: '#f5f6f2',
    domain: DesktopLyricsValueDomain.color,
    source: 'Qt/src/DesktopLyricsLayout.h:28 + Qt/src/DesktopLyricsAppearance.cpp:56',
  ),
  DesktopLyricsKeySpec(
    key: DesktopLyricsKeys.translationColor,
    defaultValue: '#f5f6f2',
    domain: DesktopLyricsValueDomain.color,
    source: 'Qt/src/DesktopLyricsLayout.h:29 + Qt/src/DesktopLyricsAppearance.cpp:57',
  ),
  DesktopLyricsKeySpec(
    key: DesktopLyricsKeys.lineWeight,
    defaultValue: 'bold',
    domain: DesktopLyricsValueDomain.weight,
    source: 'Qt/src/DesktopLyricsLayout.h:31 + Qt/src/DesktopLyricsAppearance.cpp:58',
  ),
  DesktopLyricsKeySpec(
    key: DesktopLyricsKeys.translationWeight,
    defaultValue: 'regular',
    domain: DesktopLyricsValueDomain.weight,
    source: 'Qt/src/DesktopLyricsLayout.h:32 + Qt/src/DesktopLyricsAppearance.cpp:59',
  ),
  DesktopLyricsKeySpec(
    key: DesktopLyricsKeys.lineOutline,
    defaultValue: '1.5',
    domain: DesktopLyricsValueDomain.outline,
    minimumOutline: 0,
    maximumOutline: 4,
    outlineStep: 0.5,
    source: 'Qt/src/DesktopLyricsLayout.h:24-26 + Qt/src/DesktopLyricsAppearance.cpp:60',
  ),
  DesktopLyricsKeySpec(
    key: DesktopLyricsKeys.translationOutline,
    defaultValue: '1.0',
    domain: DesktopLyricsValueDomain.outline,
    minimumOutline: 0,
    maximumOutline: 4,
    outlineStep: 0.5,
    source: 'Qt/src/DesktopLyricsLayout.h:24-25,27 + Qt/src/DesktopLyricsAppearance.cpp:61'
        '（默认 1 经 QString::number(1,"f",1) 写成 "1.0"，见 :86）',
  ),
  DesktopLyricsKeySpec(
    key: DesktopLyricsKeys.lineOutlineColor,
    defaultValue: '#000000',
    domain: DesktopLyricsValueDomain.color,
    source: 'Qt/src/DesktopLyricsLayout.h:30 + Qt/src/DesktopLyricsAppearance.cpp:62',
  ),
  DesktopLyricsKeySpec(
    key: DesktopLyricsKeys.translationOutlineColor,
    defaultValue: '#000000',
    domain: DesktopLyricsValueDomain.color,
    source: 'Qt/src/DesktopLyricsLayout.h:30 + Qt/src/DesktopLyricsAppearance.cpp:63',
  ),
];

/// 按键查表；未知键返回 null。
DesktopLyricsKeySpec? desktopLyricsKeySpec(String key) {
  for (final spec in desktopLyricsKeyTable) {
    if (spec.key == key) {
      return spec;
    }
  }
  return null;
}

// ══════════════════════════════════════════════════════════════════════════════
// 3. 两套调色板（颜色行的可选项，逐字取自 Qt 源）
// ══════════════════════════════════════════════════════════════════════════════

/// 一个（值，显示名）对：既用于 segments 的选项，也用于 palette 的色块。
class DesktopLyricsOption {
  const DesktopLyricsOption({required this.value, required this.label});

  /// 写入偏好的值（颜色行是 "#rrggbb"，字重行是 light/regular/...）。
  final String value;

  /// 显示名（中文）。
  final String label;

  @override
  bool operator ==(Object other) =>
      other is DesktopLyricsOption && other.value == value && other.label == label;

  @override
  int get hashCode => Object.hash(value, label);

  @override
  String toString() => 'DesktopLyricsOption(' + value + ' / ' + label + ')';
}

/// 正文 / 翻译的 10 个颜色（Qt/src/DesktopLyricsSettingsPage.cpp:38-49，顺序逐字）。
const List<DesktopLyricsOption> desktopLyricsTextPalette = <DesktopLyricsOption>[
  DesktopLyricsOption(value: '#f5f6f2', label: '白色'),
  DesktopLyricsOption(value: '#ffffff', label: '纯白'),
  DesktopLyricsOption(value: '#ffe9c7', label: '暖白'),
  DesktopLyricsOption(value: '#f5c76b', label: '金色'),
  DesktopLyricsOption(value: '#ff9f6b', label: '橙色'),
  DesktopLyricsOption(value: '#8fe3c0', label: '薄荷'),
  DesktopLyricsOption(value: '#7fd8e8', label: '青色'),
  DesktopLyricsOption(value: '#8fc7ff', label: '天蓝'),
  DesktopLyricsOption(value: '#ffa6c9', label: '粉色'),
  DesktopLyricsOption(value: '#d6b4ff', label: '紫色'),
];

/// 描边颜色 6 个（Qt/src/DesktopLyricsSettingsPage.cpp:51-58，顺序逐字）。
const List<DesktopLyricsOption> desktopLyricsOutlinePalette = <DesktopLyricsOption>[
  DesktopLyricsOption(value: '#000000', label: '黑色'),
  DesktopLyricsOption(value: '#2a2a2a', label: '深灰'),
  DesktopLyricsOption(value: '#3a2a1a', label: '暖黑'),
  DesktopLyricsOption(value: '#ffffff', label: '白色'),
  DesktopLyricsOption(value: '#f5f6f2', label: '米白'),
  DesktopLyricsOption(value: '#102030', label: '深蓝'),
];

/// 开关的两段（Qt/src/DesktopLyricsSettingsPage.cpp:164-167）。
const List<DesktopLyricsOption> desktopLyricsToggleOptions = <DesktopLyricsOption>[
  DesktopLyricsOption(value: 'on', label: '开启'),
  DesktopLyricsOption(value: 'off', label: '关闭'),
];

/// 字重四段（Qt/src/DesktopLyricsSettingsPage.cpp:192-197，翻译侧 :231-236 逐字相同）。
const List<DesktopLyricsOption> desktopLyricsWeightOptions = <DesktopLyricsOption>[
  DesktopLyricsOption(value: 'light', label: '细'),
  DesktopLyricsOption(value: 'regular', label: '常规'),
  DesktopLyricsOption(value: 'demibold', label: '中粗'),
  DesktopLyricsOption(value: 'bold', label: '粗'),
];

/// 偏移块的四个按钮（Qt/src/DesktopLyricsSettingsPage.cpp:274-278）。
const List<DesktopLyricsOption> desktopLyricsOffsetOptions = <DesktopLyricsOption>[
  DesktopLyricsOption(value: 'desktop-lyrics:offset-earlier', label: '提前 0.2s'),
  DesktopLyricsOption(value: 'desktop-lyrics:offset-later', label: '延后 0.2s'),
  DesktopLyricsOption(value: 'desktop-lyrics:offset-reset', label: '重置'),
  DesktopLyricsOption(value: 'desktop-lyrics:offset-global', label: '设为全局'),
];

/// 字重白名单（Qt/src/DesktopLyricsAppearance.cpp:32-35 的 readWeight 与
/// Qt/src/NativeHudDesktopLyrics.cpp:175-177 的 writeWeight 用同一组值）。
const List<String> desktopLyricsWeights = <String>['light', 'regular', 'demibold', 'bold'];

// ══════════════════════════════════════════════════════════════════════════════
// 4. 解析与规范化（逐条等价 Qt/src/DesktopLyricsAppearance.cpp:10-35）
// ══════════════════════════════════════════════════════════════════════════════

bool _isWhitespace(int unit) =>
    unit == 0x20 || unit == 0x09 || unit == 0x0A || unit == 0x0B || unit == 0x0C || unit == 0x0D;

bool _isDigit(int unit) => unit >= 0x30 && unit <= 0x39;

bool _isHexDigit(int unit) =>
    (unit >= 0x30 && unit <= 0x39) || (unit >= 0x41 && unit <= 0x46) || (unit >= 0x61 && unit <= 0x66);

/// Qt `QString::toInt(bool *ok)` 的等价解析：跳过前导空白，允许 +/-，
/// 只接受十进制数字并且必须整串消费；非法或溢出返回 null（Qt 置 ok=false）。
int? desktopLyricsParseInt(String raw) {
  var index = 0;
  while (index < raw.length && _isWhitespace(raw.codeUnitAt(index))) {
    index += 1;
  }
  final start = index;
  if (index < raw.length) {
    final unit = raw.codeUnitAt(index);
    if (unit == 0x2B || unit == 0x2D) {
      index += 1;
    }
  }
  final digitsStart = index;
  while (index < raw.length && _isDigit(raw.codeUnitAt(index))) {
    index += 1;
  }
  if (index == digitsStart || index != raw.length) {
    return null;
  }
  return int.tryParse(raw.substring(start));
}

/// Qt `QString::toDouble(bool *ok)` 的等价解析：跳过前导空白，允许 +/-、
/// 小数点与十进制指数，另外接受 qstrtod 的 inf / infinity / nan（大小写不敏感）。
double? desktopLyricsParseDouble(String raw) {
  var index = 0;
  while (index < raw.length && _isWhitespace(raw.codeUnitAt(index))) {
    index += 1;
  }
  if (index >= raw.length) {
    return null;
  }
  final body = raw.substring(index);
  final lower = body.toLowerCase();
  switch (lower) {
    case 'inf':
    case '+inf':
    case 'infinity':
    case '+infinity':
      return double.infinity;
    case '-inf':
    case '-infinity':
      return double.negativeInfinity;
    case 'nan':
    case '+nan':
    case '-nan':
      return double.nan;
  }
  var cursor = 0;
  if (body[cursor] == '+' || body[cursor] == '-') {
    cursor += 1;
  }
  var digits = 0;
  while (cursor < body.length && _isDigit(body.codeUnitAt(cursor))) {
    cursor += 1;
    digits += 1;
  }
  if (cursor < body.length && body[cursor] == '.') {
    cursor += 1;
    while (cursor < body.length && _isDigit(body.codeUnitAt(cursor))) {
      cursor += 1;
      digits += 1;
    }
  }
  if (digits == 0) {
    return null;
  }
  if (cursor < body.length && (body[cursor] == 'e' || body[cursor] == 'E')) {
    cursor += 1;
    if (cursor < body.length && (body[cursor] == '+' || body[cursor] == '-')) {
      cursor += 1;
    }
    final exponentStart = cursor;
    while (cursor < body.length && _isDigit(body.codeUnitAt(cursor))) {
      cursor += 1;
    }
    if (cursor == exponentStart) {
      return null;
    }
  }
  if (cursor != body.length) {
    return null;
  }
  return double.tryParse(body);
}

/// Qt `QString::number(double, 'f', 1)` 的等价序列化
/// （Qt/src/DesktopLyricsAppearance.cpp:18、:82、:86 与
/// Qt/src/DesktopLyricsSettingsPage.cpp:207-211、:246-250 都用一位小数）。
String desktopLyricsFormatFixed1(double value) {
  if (value.isNaN) {
    return 'nan';
  }
  if (value.isInfinite) {
    return value > 0 ? 'inf' : '-inf';
  }
  return value.toStringAsFixed(1);
}

/// `std::clamp` 的等价实现（Qt/src/DesktopLyricsAppearance.cpp:13、:17、
/// Qt/src/DesktopLyricsSettingsPage.cpp:206、:245 都用它）：
/// NaN 会原样穿过（两个比较都为 false），与 libstdc++ 的 clamp 一致。
double desktopLyricsClampDouble(double value, double minimum, double maximum) =>
    value < minimum ? minimum : (maximum < value ? maximum : value);

/// 整数版 clamp（Qt/src/DesktopLyricsAppearance.cpp:13 与
/// Qt/src/NativeHudDesktopLyrics.cpp:150-155）。
int desktopLyricsClampInt(int value, int minimum, int maximum) =>
    value < minimum ? minimum : (value > maximum ? maximum : value);

/// 四舍五入到步长整数倍（Qt `std::round(v / step) * step`，
/// Qt/src/DesktopLyricsAppearance.cpp:20 与 Qt/src/NativeHudDesktopLyrics.cpp:167-168）；
/// std::round 半值远离零，Dart 的 roundToDouble 同语义。NaN 原样返回。
double desktopLyricsRoundToStep(double value, double step) {
  if (value.isNaN) {
    return double.nan;
  }
  return (value / step).roundToDouble() * step;
}

/// Qt/src/DesktopLyricsAppearance.cpp:10-14 readInteger 的等价实现：
/// toInt 失败直接回落 fallback（不 clamp fallback），成功则 clamp 到闭区间。
int normalizeDesktopLyricsInteger(
  String raw, {
  required int fallback,
  required int minimum,
  required int maximum,
}) {
  final parsed = desktopLyricsParseInt(raw);
  if (parsed == null) {
    return fallback;
  }
  return desktopLyricsClampInt(parsed, minimum, maximum);
}

/// Qt/src/DesktopLyricsAppearance.cpp:16-21 readOutline 的等价实现：
/// 失败用 fallback，然后无论成功失败都 clamp 到 [0, 4] 并四舍五入到 0.5 的整数倍。
double normalizeDesktopLyricsOutlineValue(
  String raw, {
  required double fallback,
  double maximum = DesktopLyricsDefaults.maximumOutline,
  double step = DesktopLyricsDefaults.outlineStep,
}) {
  final parsed = desktopLyricsParseDouble(raw);
  final clamped = desktopLyricsClampDouble(parsed ?? fallback, 0, maximum);
  return desktopLyricsRoundToStep(clamped, step);
}

/// 描边的规范字符串形式：clamp + 四舍五入后写成一位小数（"1.5" / "0.0"）。
String normalizeDesktopLyricsOutline(String raw, {required double fallback}) =>
    desktopLyricsFormatFixed1(normalizeDesktopLyricsOutlineValue(raw, fallback: fallback));

/// Qt/src/DesktopLyricsAppearance.cpp:23-29 readColor 的等价实现：
/// QColor 校验通过则写 name(HexRgb).toLower()，失败回落 fallback.toLower()。
String normalizeDesktopLyricsColor(String raw, {required String fallback}) {
  final normalized = desktopLyricsNormalizeHexColor(raw);
  if (normalized != null) {
    return normalized;
  }
  return fallback.toLowerCase();
}

/// `QColor(value).name(QColor::HexRgb).toLower()` 的等价实现
/// （Qt/src/DesktopLyricsAppearance.cpp:26）。
///
/// 只实现设置页实际会写出的两种短形式：`#RGB` 与 `#RRGGBB`；
/// 其它 QColor 文本形式（命名色、`#AARRGGBB`、`#RRRGGGBBB`、
/// `rgb()` / `hsl()`）不在这里实现，会走 fallback，
/// 见文件末尾「已知边界」。
String? desktopLyricsNormalizeHexColor(String raw) {
  if (raw.length != 4 && raw.length != 7) {
    return null;
  }
  if (!raw.startsWith('#')) {
    return null;
  }
  final body = raw.substring(1);
  for (var index = 0; index < body.length; index += 1) {
    if (!_isHexDigit(body.codeUnitAt(index))) {
      return null;
    }
  }
  final lower = body.toLowerCase();
  if (lower.length == 6) {
    return '#' + lower;
  }
  final expanded = StringBuffer('#');
  for (var index = 0; index < 3; index += 1) {
    expanded.write(lower[index]);
    expanded.write(lower[index]);
  }
  return expanded.toString();
}

/// Qt/src/DesktopLyricsAppearance.cpp:31-35 readWeight 的等价实现：
/// 白名单外回落 fallback（Qt 的回落不做小写化，这里同样不做）。
String normalizeDesktopLyricsWeight(String raw, {required String fallback}) =>
    desktopLyricsWeights.contains(raw) ? raw : fallback;

/// 按键规范化一次写入值（写入门控的纯函数版，Qt/src/NativeHudDesktopLyrics.cpp:146-217）。
///
/// 未知键原样返回（Qt 的分发器对未知 name 不写任何键，见 :218-219）。
String normalizeDesktopLyricsValue(String key, String raw) {
  final spec = desktopLyricsKeySpec(key);
  if (spec == null) {
    return raw;
  }
  switch (spec.domain) {
    case DesktopLyricsValueDomain.toggle:
      // Qt/src/NativeHudDesktopLyrics.cpp:181-183：无条件写，只有 "on" 保留。
      return raw == 'on' ? 'on' : 'off';
    case DesktopLyricsValueDomain.integer:
      return normalizeDesktopLyricsInteger(
        raw,
        fallback: int.parse(spec.defaultValue),
        minimum: spec.minimum!,
        maximum: spec.maximum!,
      ).toString();
    case DesktopLyricsValueDomain.outline:
      return normalizeDesktopLyricsOutline(raw, fallback: double.parse(spec.defaultValue));
    case DesktopLyricsValueDomain.color:
      return normalizeDesktopLyricsColor(raw, fallback: spec.defaultValue);
    case DesktopLyricsValueDomain.weight:
      return normalizeDesktopLyricsWeight(raw, fallback: spec.defaultValue);
  }
}

/// 是否为外观键（Qt/src/DesktopLyricsAppearance.cpp:91-101 isAppearanceKey）：
/// 12 个键里除开关以外的 11 个（desktop-lyrics-size 与其余 10 项），开关本身不算。
bool isDesktopLyricsAppearanceKey(String key) {
  final spec = desktopLyricsKeySpec(key);
  if (spec == null) {
    return false;
  }
  return spec.domain != DesktopLyricsValueDomain.toggle;
}

/// 键表自洽性：每个默认值必须已经是规范形式，否则「恢复默认样式」写出的值会被读取器
/// 再次改写（例如把 "1" 读成 1.0 再写成 "1.0"）。
bool desktopLyricsKeyTableIsConsistent() {
  for (final spec in desktopLyricsKeyTable) {
    if (normalizeDesktopLyricsValue(spec.key, spec.defaultValue) != spec.defaultValue) {
      return false;
    }
  }
  return true;
}

/// 十六进制颜色 → 0..1 的 RGBA（Qt/src/DesktopLyricsSettingsPage.cpp:60-62 的 colorArray：
/// `{redF, greenF, blueF, 1.0}`，alpha 恒为 1）。
///
/// 非法输入返回不透明黑：QColor 默认构造无效，redF()/greenF()/blueF() 都是 0。
SettingsRgba desktopLyricsRgbaFromHex(String value) {
  final normalized = desktopLyricsNormalizeHexColor(value);
  if (normalized == null) {
    return const SettingsRgba(0, 0, 0, 1);
  }
  final red = int.parse(normalized.substring(1, 3), radix: 16);
  final green = int.parse(normalized.substring(3, 5), radix: 16);
  final blue = int.parse(normalized.substring(5, 7), radix: 16);
  return SettingsRgba(red / 255, green / 255, blue / 255, 1);
}

// ══════════════════════════════════════════════════════════════════════════════
// 5. 外观结构（Qt/src/DesktopLyricsLayout.h:56-69 的 11 个字段）
// ══════════════════════════════════════════════════════════════════════════════

/// 桌面歌词外观：11 个字段，默认值取 Qt/src/DesktopLyricsLayout.h:15-32。
class DesktopLyricsAppearance {
  const DesktopLyricsAppearance({
    this.lineSize = DesktopLyricsDefaults.lineSize,
    this.translationSize = DesktopLyricsDefaults.translationSize,
    this.opacity = DesktopLyricsDefaults.opacity,
    this.lineColor = DesktopLyricsDefaults.lineColor,
    this.translationColor = DesktopLyricsDefaults.translationColor,
    this.lineWeight = DesktopLyricsDefaults.lineWeight,
    this.translationWeight = DesktopLyricsDefaults.translationWeight,
    this.lineOutline = DesktopLyricsDefaults.lineOutline,
    this.translationOutline = DesktopLyricsDefaults.translationOutline,
    this.lineOutlineColor = DesktopLyricsDefaults.outlineColor,
    this.translationOutlineColor = DesktopLyricsDefaults.outlineColor,
  });

  final int lineSize;
  final int translationSize;
  final int opacity;
  final String lineColor;
  final String translationColor;
  final String lineWeight;
  final String translationWeight;
  final double lineOutline;
  final double translationOutline;
  final String lineOutlineColor;
  final String translationOutlineColor;

  /// Qt 的默认结构（Qt/src/DesktopLyricsAppearance.cpp:51-52：host 为空时直接返回它）。
  static const DesktopLyricsAppearance defaults = DesktopLyricsAppearance();

  /// 逐键读取（Qt/src/DesktopLyricsAppearance.cpp:49-72 readAppearance）。
  ///
  /// `read` 对缺失键返回空串即可：Qt 的 preference() 缺失时也是空串，
  /// 四个读取器都会回落到默认值。
  factory DesktopLyricsAppearance.fromPreferences(String Function(String key) read) {
    return DesktopLyricsAppearance(
      lineSize: normalizeDesktopLyricsInteger(
        read(DesktopLyricsKeys.lineSize),
        fallback: DesktopLyricsDefaults.lineSize,
        minimum: DesktopLyricsDefaults.minimumLineSize,
        maximum: DesktopLyricsDefaults.maximumLineSize,
      ),
      translationSize: normalizeDesktopLyricsInteger(
        read(DesktopLyricsKeys.translationSize),
        fallback: DesktopLyricsDefaults.translationSize,
        minimum: DesktopLyricsDefaults.minimumTranslationSize,
        maximum: DesktopLyricsDefaults.maximumTranslationSize,
      ),
      opacity: normalizeDesktopLyricsInteger(
        read(DesktopLyricsKeys.opacity),
        fallback: DesktopLyricsDefaults.opacity,
        minimum: DesktopLyricsDefaults.minimumOpacity,
        maximum: DesktopLyricsDefaults.maximumOpacity,
      ),
      lineColor: normalizeDesktopLyricsColor(
        read(DesktopLyricsKeys.lineColor),
        fallback: DesktopLyricsDefaults.lineColor,
      ),
      translationColor: normalizeDesktopLyricsColor(
        read(DesktopLyricsKeys.translationColor),
        fallback: DesktopLyricsDefaults.translationColor,
      ),
      lineWeight: normalizeDesktopLyricsWeight(
        read(DesktopLyricsKeys.lineWeight),
        fallback: DesktopLyricsDefaults.lineWeight,
      ),
      translationWeight: normalizeDesktopLyricsWeight(
        read(DesktopLyricsKeys.translationWeight),
        fallback: DesktopLyricsDefaults.translationWeight,
      ),
      lineOutline: normalizeDesktopLyricsOutlineValue(
        read(DesktopLyricsKeys.lineOutline),
        fallback: DesktopLyricsDefaults.lineOutline,
      ),
      translationOutline: normalizeDesktopLyricsOutlineValue(
        read(DesktopLyricsKeys.translationOutline),
        fallback: DesktopLyricsDefaults.translationOutline,
      ),
      lineOutlineColor: normalizeDesktopLyricsColor(
        read(DesktopLyricsKeys.lineOutlineColor),
        fallback: DesktopLyricsDefaults.outlineColor,
      ),
      translationOutlineColor: normalizeDesktopLyricsColor(
        read(DesktopLyricsKeys.translationOutlineColor),
        fallback: DesktopLyricsDefaults.outlineColor,
      ),
    );
  }

  /// 从偏好表读取（缺失键按空串处理）。
  factory DesktopLyricsAppearance.fromMap(Map<String, String> preferences) =>
      DesktopLyricsAppearance.fromPreferences((key) => preferences[key] ?? '');

  /// 某键的规范字符串（未知名返回空串）。
  String valueFor(String key) {
    switch (key) {
      case DesktopLyricsKeys.lineSize:
        return lineSize.toString();
      case DesktopLyricsKeys.translationSize:
        return translationSize.toString();
      case DesktopLyricsKeys.opacity:
        return opacity.toString();
      case DesktopLyricsKeys.lineColor:
        return lineColor;
      case DesktopLyricsKeys.translationColor:
        return translationColor;
      case DesktopLyricsKeys.lineWeight:
        return lineWeight;
      case DesktopLyricsKeys.translationWeight:
        return translationWeight;
      case DesktopLyricsKeys.lineOutline:
        return desktopLyricsFormatFixed1(lineOutline);
      case DesktopLyricsKeys.translationOutline:
        return desktopLyricsFormatFixed1(translationOutline);
      case DesktopLyricsKeys.lineOutlineColor:
        return lineOutlineColor;
      case DesktopLyricsKeys.translationOutlineColor:
        return translationOutlineColor;
      default:
        return '';
    }
  }

  /// 应用一次写入后的新结构（值先经 normalizeDesktopLyricsValue 规范化）。
  DesktopLyricsAppearance withValue(String key, String raw) {
    final normalized = normalizeDesktopLyricsValue(key, raw);
    switch (key) {
      case DesktopLyricsKeys.lineSize:
        return copyWith(lineSize: desktopLyricsParseInt(normalized) ?? lineSize);
      case DesktopLyricsKeys.translationSize:
        return copyWith(translationSize: desktopLyricsParseInt(normalized) ?? translationSize);
      case DesktopLyricsKeys.opacity:
        return copyWith(opacity: desktopLyricsParseInt(normalized) ?? opacity);
      case DesktopLyricsKeys.lineColor:
        return copyWith(lineColor: normalized);
      case DesktopLyricsKeys.translationColor:
        return copyWith(translationColor: normalized);
      case DesktopLyricsKeys.lineWeight:
        return copyWith(lineWeight: normalized);
      case DesktopLyricsKeys.translationWeight:
        return copyWith(translationWeight: normalized);
      case DesktopLyricsKeys.lineOutline:
        return copyWith(lineOutline: desktopLyricsParseDouble(normalized) ?? lineOutline);
      case DesktopLyricsKeys.translationOutline:
        return copyWith(translationOutline: desktopLyricsParseDouble(normalized) ?? translationOutline);
      case DesktopLyricsKeys.lineOutlineColor:
        return copyWith(lineOutlineColor: normalized);
      case DesktopLyricsKeys.translationOutlineColor:
        return copyWith(translationOutlineColor: normalized);
      default:
        return this;
    }
  }

  DesktopLyricsAppearance copyWith({
    int? lineSize,
    int? translationSize,
    int? opacity,
    String? lineColor,
    String? translationColor,
    String? lineWeight,
    String? translationWeight,
    double? lineOutline,
    double? translationOutline,
    String? lineOutlineColor,
    String? translationOutlineColor,
  }) {
    return DesktopLyricsAppearance(
      lineSize: lineSize ?? this.lineSize,
      translationSize: translationSize ?? this.translationSize,
      opacity: opacity ?? this.opacity,
      lineColor: lineColor ?? this.lineColor,
      translationColor: translationColor ?? this.translationColor,
      lineWeight: lineWeight ?? this.lineWeight,
      translationWeight: translationWeight ?? this.translationWeight,
      lineOutline: lineOutline ?? this.lineOutline,
      translationOutline: translationOutline ?? this.translationOutline,
      lineOutlineColor: lineOutlineColor ?? this.lineOutlineColor,
      translationOutlineColor: translationOutlineColor ?? this.translationOutlineColor,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is DesktopLyricsAppearance &&
      other.lineSize == lineSize &&
      other.translationSize == translationSize &&
      other.opacity == opacity &&
      other.lineColor == lineColor &&
      other.translationColor == translationColor &&
      other.lineWeight == lineWeight &&
      other.translationWeight == translationWeight &&
      other.lineOutline == lineOutline &&
      other.translationOutline == translationOutline &&
      other.lineOutlineColor == lineOutlineColor &&
      other.translationOutlineColor == translationOutlineColor;

  @override
  int get hashCode => Object.hash(lineSize, translationSize, opacity, lineColor, translationColor,
      lineWeight, translationWeight, lineOutline, translationOutline, lineOutlineColor,
      translationOutlineColor);

  @override
  String toString() => 'DesktopLyricsAppearance(lineSize: ' +
      lineSize.toString() +
      ', translationSize: ' +
      translationSize.toString() +
      ', opacity: ' +
      opacity.toString() +
      ', lineColor: ' +
      lineColor +
      ', translationColor: ' +
      translationColor +
      ', lineWeight: ' +
      lineWeight +
      ', translationWeight: ' +
      translationWeight +
      ', lineOutline: ' +
      desktopLyricsFormatFixed1(lineOutline) +
      ', translationOutline: ' +
      desktopLyricsFormatFixed1(translationOutline) +
      ', lineOutlineColor: ' +
      lineOutlineColor +
      ', translationOutlineColor: ' +
      translationOutlineColor +
      ')'; 
}

// ══════════════════════════════════════════════════════════════════════════════
// 6. 恢复默认（resetAppearance 与「恢复默认设置」）
// ══════════════════════════════════════════════════════════════════════════════

/// 一次偏好写入（键 + 规范值）。
class DesktopLyricsWrite {
  const DesktopLyricsWrite(this.key, this.value);

  final String key;
  final String value;

  @override
  bool operator ==(Object other) =>
      other is DesktopLyricsWrite && other.key == key && other.value == value;

  @override
  int get hashCode => Object.hash(key, value);

  @override
  String toString() => 'DesktopLyricsWrite(' + key + ' = ' + value + ')';
}

/// 「恢复默认样式」按钮的写入序列。
///
/// Qt/src/DesktopLyricsAppearance.cpp:74-89 的 11 次写入，顺序逐字：
/// 字号 → 翻译字号 → 透明度 → 正文颜色 → 翻译颜色 → 正文字重 → 翻译字重 →
/// 正文描边 → 翻译描边 → 正文描边颜色 → 翻译描边颜色。
///
/// 开关（desktop-lyrics）不在这里重置：Qt/src/DesktopLyricsSettingsPage.cpp:299 的
/// 说明文字就是「开关和偏移保持不变」。
List<DesktopLyricsWrite> planDesktopLyricsReset() => const <DesktopLyricsWrite>[
      DesktopLyricsWrite(DesktopLyricsKeys.lineSize, '32'),
      DesktopLyricsWrite(DesktopLyricsKeys.translationSize, '24'),
      DesktopLyricsWrite(DesktopLyricsKeys.opacity, '100'),
      DesktopLyricsWrite(DesktopLyricsKeys.lineColor, '#f5f6f2'),
      DesktopLyricsWrite(DesktopLyricsKeys.translationColor, '#f5f6f2'),
      DesktopLyricsWrite(DesktopLyricsKeys.lineWeight, 'bold'),
      DesktopLyricsWrite(DesktopLyricsKeys.translationWeight, 'regular'),
      DesktopLyricsWrite(DesktopLyricsKeys.lineOutline, '1.5'),
      DesktopLyricsWrite(DesktopLyricsKeys.translationOutline, '1.0'),
      DesktopLyricsWrite(DesktopLyricsKeys.lineOutlineColor, '#000000'),
      DesktopLyricsWrite(DesktopLyricsKeys.translationOutlineColor, '#000000'),
    ];

/// 「恢复默认设置」对桌面歌词的写入（Qt/src/NativeHudSettings.cpp:516-519）：
/// 先写开关 off，再 resetAppearance（11 个外观键），最后把外观缓存标记为未加载。
///
/// 平台矩阵：只有 restoreShouldTouchDesktopLyrics(caps) 为 true 时才应执行这段。
List<DesktopLyricsWrite> planDesktopLyricsRestoreDefaults() => <DesktopLyricsWrite>[
      const DesktopLyricsWrite(DesktopLyricsKeys.enabled, 'off'),
      ...planDesktopLyricsReset(),
    ];

// ══════════════════════════════════════════════════════════════════════════════
// 7. 文案与动作串
// ══════════════════════════════════════════════════════════════════════════════

/// 模态与设置页入口的文案，逐字取自 Qt 源。
class DesktopLyricsCopy {
  const DesktopLyricsCopy._();

  /// Qt/src/NativeHudModal.cpp:29（modalTitle 的键）
  static const String modalId = 'desktop-lyrics';

  /// Qt/src/NativeHudModal.cpp:29
  static const String modalTitle = 'DESKTOP LYRICS';

  /// Qt/src/NativeHudModal.cpp:55
  static const String modalSubtitle = '桌面歌词 / 样式与同步';

  /// Qt/src/NativeHudModal.cpp:192
  static const String modalCategory = 'DESKTOP LYRICS';

  /// Qt/src/NativeHudModal.cpp:199
  static const String backLabel = '← 返回';

  /// Qt/src/SettingsSchema.cpp:488
  static const String entryTitleEn = 'DESKTOP LYRICS';

  /// Qt/src/SettingsSchema.cpp:489
  static const String entryTitleZh = '桌面歌词';

  /// Qt/src/SettingsSchema.cpp:490
  static const String entryActionLabel = '样式与同步';

  /// Qt/src/DesktopLyricsSettingsPage.cpp:162
  static const String sectionDisplayEn = 'DISPLAY';

  /// Qt/src/DesktopLyricsSettingsPage.cpp:162
  static const String sectionDisplayZh = '显示';

  /// Qt/src/DesktopLyricsSettingsPage.cpp:181
  static const String sectionLyricEn = 'LYRIC';

  /// Qt/src/DesktopLyricsSettingsPage.cpp:181
  static const String sectionLyricZh = '正文';

  /// Qt/src/DesktopLyricsSettingsPage.cpp:220
  static const String sectionTranslationEn = 'TRANSLATION';

  /// Qt/src/DesktopLyricsSettingsPage.cpp:220
  static const String sectionTranslationZh = '翻译';

  /// Qt/src/DesktopLyricsSettingsPage.cpp:259
  static const String sectionSyncEn = 'SYNC';

  /// Qt/src/DesktopLyricsSettingsPage.cpp:259
  static const String sectionSyncZh = '同步';

  /// Qt/src/DesktopLyricsSettingsPage.cpp:291
  static const String sectionResetEn = 'RESET';

  /// Qt/src/DesktopLyricsSettingsPage.cpp:291
  static const String sectionResetZh = '重置';

  /// Qt/src/DesktopLyricsSettingsPage.cpp:295 / :298
  static const String resetLabel = '恢复默认样式';

  /// Qt/src/DesktopLyricsSettingsPage.cpp:299
  static const String resetNote = '恢复字号、颜色、描边与透明度；开关和偏移保持不变。';

  /// Qt/src/DesktopLyricsSettingsPage.cpp:270
  static const String offsetNote = '与歌词页共用同一偏移；调整后悬浮歌词立即同步。';

  /// Qt/src/DesktopLyricsSettingsPage.cpp:263
  static const String offsetUncalibrated = '未校准';

  /// Qt/src/DesktopLyricsSettingsPage.cpp:265
  static const String offsetAheadPrefix = '已提前 ';

  /// Qt/src/DesktopLyricsSettingsPage.cpp:265
  static const String offsetBehindPrefix = '已延后 ';

  /// Qt/src/DesktopLyricsSettingsPage.cpp:267
  static const String offsetSecondsSuffix = ' 秒';

  /// Qt/src/DesktopLyricsSettingsPage.cpp:261
  static const String offsetTitleEn = 'OFFSET';

  /// Qt/src/DesktopLyricsSettingsPage.cpp:262
  static const String offsetTitleZh = '歌词偏移';
}

/// 动作串，逐字取自 Qt 源。
class DesktopLyricsActions {
  const DesktopLyricsActions._();

  /// Qt/src/NativeHudDesktopLyrics.cpp:122
  static const String prefix = 'desktop-lyrics:';

  /// Qt/src/SettingsSchema.cpp:486（设置页入口按钮）
  static const String open = 'desktop-lyrics:open';

  /// Qt/src/NativeHudModal.cpp:200
  static const String back = 'desktop-lyrics:back';

  /// Qt/src/NativeHudDesktopLyrics.cpp:117
  static const String scrollUp = 'desktop-lyrics:scroll-up';

  /// Qt/src/NativeHudDesktopLyrics.cpp:118
  static const String scrollDown = 'desktop-lyrics:scroll-down';

  /// Qt/src/DesktopLyricsSettingsPage.cpp:169
  static const String enabledPrefix = 'desktop-lyrics:enabled:';

  /// Qt/src/DesktopLyricsSettingsPage.cpp:175-176
  static const String opacityPrefix = 'desktop-lyrics:opacity:';

  /// Qt/src/DesktopLyricsSettingsPage.cpp:185-188
  static const String lineSizePrefix = 'desktop-lyrics:line-size:';

  /// Qt/src/DesktopLyricsSettingsPage.cpp:224-227
  static const String translationSizePrefix = 'desktop-lyrics:translation-size:';

  /// Qt/src/DesktopLyricsSettingsPage.cpp:199
  static const String lineWeightPrefix = 'desktop-lyrics:line-weight:';

  /// Qt/src/DesktopLyricsSettingsPage.cpp:238
  static const String translationWeightPrefix = 'desktop-lyrics:translation-weight:';

  /// Qt/src/DesktopLyricsSettingsPage.cpp:202
  static const String lineColorPrefix = 'desktop-lyrics:line-color:';

  /// Qt/src/DesktopLyricsSettingsPage.cpp:241
  static const String translationColorPrefix = 'desktop-lyrics:translation-color:';

  /// Qt/src/DesktopLyricsSettingsPage.cpp:208-211
  static const String lineOutlinePrefix = 'desktop-lyrics:line-outline:';

  /// Qt/src/DesktopLyricsSettingsPage.cpp:247-250
  static const String translationOutlinePrefix = 'desktop-lyrics:translation-outline:';

  /// Qt/src/DesktopLyricsSettingsPage.cpp:216
  static const String lineOutlineColorPrefix = 'desktop-lyrics:line-outline-color:';

  /// Qt/src/DesktopLyricsSettingsPage.cpp:255
  static const String translationOutlineColorPrefix = 'desktop-lyrics:translation-outline-color:';

  /// Qt/src/DesktopLyricsSettingsPage.cpp:277
  static const String offsetEarlier = 'desktop-lyrics:offset-earlier';

  /// Qt/src/DesktopLyricsSettingsPage.cpp:277
  static const String offsetLater = 'desktop-lyrics:offset-later';

  /// Qt/src/DesktopLyricsSettingsPage.cpp:278
  static const String offsetReset = 'desktop-lyrics:offset-reset';

  /// Qt/src/DesktopLyricsSettingsPage.cpp:278
  static const String offsetGlobal = 'desktop-lyrics:offset-global';

  /// Qt/src/DesktopLyricsSettingsPage.cpp:298
  static const String resetStyle = 'desktop-lyrics:reset-style';

  /// Qt/src/DesktopLyricsSettingsPage.cpp:64-66：`QString::fromLatin1(prefix) + value`
  static String actionFor(String actionPrefix, String value) => actionPrefix + value;
}

// ══════════════════════════════════════════════════════════════════════════════
// 8. 动作分发（Qt/src/NativeHudDesktopLyrics.cpp:121-219 的纯函数版）
// ══════════════════════════════════════════════════════════════════════════════

/// 分发后会切到的模态（Qt/src/NativeHudDesktopLyrics.cpp:127-135）。
enum DesktopLyricsModalRoute { desktopLyrics, settings }

/// 播放器侧偏移命令（Qt/src/NativeHudDesktopLyrics.cpp:211-214）。
enum DesktopLyricsPlayerCommand { offsetEarlier, offsetLater, offsetReset, offsetGlobal }

/// 一次 desktop-lyrics: 动作的分发结果。
class DesktopLyricsActionPlan {
  const DesktopLyricsActionPlan({
    required this.action,
    required this.name,
    required this.argument,
    this.matched = false,
    this.route,
    this.scrollDelta,
    this.write,
    this.playerCommand,
    this.resetsAppearance = false,
    this.dropsAppearanceCache = true,
  });

  /// 原始动作串。
  final String action;

  /// 前缀之后按 ':' 切开的第一段（Qt `parts.value(0)`，:124）。
  final String name;

  /// 第二段，越界为空串（Qt `parts.value(1)`，:125）。
  final String argument;

  /// 是否命中已知分支。未命中时 Qt 仍会执行收尾（:218-219）。
  final bool matched;

  /// open / back 的模态跳转。
  final DesktopLyricsModalRoute? route;

  /// scroll-up / scroll-down 的位移（-120 / +120，:139）。
  final double? scrollDelta;

  /// 要写进偏好的键值（已规范化）。
  final DesktopLyricsWrite? write;

  /// 播放器侧的偏移命令。
  final DesktopLyricsPlayerCommand? playerCommand;

  /// 是否调用 resetAppearance（:215-216）。
  final bool resetsAppearance;

  /// 是否把外观缓存标记为未加载（:218-219 的收尾）。
  ///
  /// open / back / scroll-* 三个分支在 Qt 里提前 return，不会走到收尾。
  final bool dropsAppearanceCache;

  @override
  String toString() => 'DesktopLyricsActionPlan(' +
      name +
      ' / ' +
      argument +
      ', matched: ' +
      matched.toString() +
      ', write: ' +
      (write?.toString() ?? 'none') +
      ')';
}

/// 解析并分发一个 desktop-lyrics: 动作；前缀不匹配返回 null。
///
/// 逐条对应 Qt/src/NativeHudDesktopLyrics.cpp:121-219。
DesktopLyricsActionPlan? planDesktopLyricsAction(String action) {
  if (!action.startsWith(DesktopLyricsActions.prefix)) {
    return null;
  }
  final rest = action.substring(DesktopLyricsActions.prefix.length);
  final parts = rest.split(':');
  final name = parts.isEmpty ? '' : parts[0];
  final argument = parts.length > 1 ? parts[1] : '';

  DesktopLyricsActionPlan matchedPlan({
    DesktopLyricsModalRoute? route,
    double? scrollDelta,
    DesktopLyricsWrite? write,
    DesktopLyricsPlayerCommand? playerCommand,
    bool resetsAppearance = false,
    bool dropsAppearanceCache = true,
  }) {
    return DesktopLyricsActionPlan(
      action: action,
      name: name,
      argument: argument,
      matched: true,
      route: route,
      scrollDelta: scrollDelta,
      write: write,
      playerCommand: playerCommand,
      resetsAppearance: resetsAppearance,
      dropsAppearanceCache: dropsAppearanceCache,
    );
  }

  // Qt/src/NativeHudDesktopLyrics.cpp:127-144：三个提前 return 的分支。
  switch (name) {
    case 'open':
      return matchedPlan(route: DesktopLyricsModalRoute.desktopLyrics, dropsAppearanceCache: false);
    case 'back':
      return matchedPlan(route: DesktopLyricsModalRoute.settings, dropsAppearanceCache: false);
    case 'scroll-up':
      return matchedPlan(scrollDelta: -DesktopLyricsPageMetrics.scrollButtonStep, dropsAppearanceCache: false);
    case 'scroll-down':
      return matchedPlan(scrollDelta: DesktopLyricsPageMetrics.scrollButtonStep, dropsAppearanceCache: false);
  }

  // Qt/src/NativeHudDesktopLyrics.cpp:181-183：开关无条件写。
  if (name == 'enabled') {
    return matchedPlan(write: DesktopLyricsWrite(DesktopLyricsKeys.enabled, argument == 'on' ? 'on' : 'off'));
  }

  // Qt/src/NativeHudDesktopLyrics.cpp:184-186 writeInteger(OpacityKey, 20, 100)
  if (name == 'opacity') {
    final parsed = desktopLyricsParseInt(argument);
    if (parsed == null) {
      return matchedPlan();
    }
    return matchedPlan(
      write: DesktopLyricsWrite(
        DesktopLyricsKeys.opacity,
        desktopLyricsClampInt(parsed, DesktopLyricsDefaults.minimumOpacity, DesktopLyricsDefaults.maximumOpacity)
            .toString(),
      ),
    );
  }

  // Qt/src/NativeHudDesktopLyrics.cpp:187-189 writeInteger(LineSizeKey, 20, 60)
  if (name == 'line-size') {
    final parsed = desktopLyricsParseInt(argument);
    if (parsed == null) {
      return matchedPlan();
    }
    return matchedPlan(
      write: DesktopLyricsWrite(
        DesktopLyricsKeys.lineSize,
        desktopLyricsClampInt(parsed, DesktopLyricsDefaults.minimumLineSize, DesktopLyricsDefaults.maximumLineSize)
            .toString(),
      ),
    );
  }

  // Qt/src/NativeHudDesktopLyrics.cpp:190-192 writeInteger(TranslationSizeKey, 16, 48)
  if (name == 'translation-size') {
    final parsed = desktopLyricsParseInt(argument);
    if (parsed == null) {
      return matchedPlan();
    }
    return matchedPlan(
      write: DesktopLyricsWrite(
        DesktopLyricsKeys.translationSize,
        desktopLyricsClampInt(parsed, DesktopLyricsDefaults.minimumTranslationSize,
                DesktopLyricsDefaults.maximumTranslationSize)
            .toString(),
      ),
    );
  }

  // Qt/src/NativeHudDesktopLyrics.cpp:193-198 writeWeight
  if (name == 'line-weight' || name == 'translation-weight') {
    if (!desktopLyricsWeights.contains(argument)) {
      return matchedPlan();
    }
    final key = name == 'line-weight' ? DesktopLyricsKeys.lineWeight : DesktopLyricsKeys.translationWeight;
    return matchedPlan(write: DesktopLyricsWrite(key, argument));
  }

  // Qt/src/NativeHudDesktopLyrics.cpp:199-206 writeColor
  if (name == 'line-color' ||
      name == 'translation-color' ||
      name == 'line-outline-color' ||
      name == 'translation-outline-color') {
    final normalized = desktopLyricsNormalizeHexColor(argument);
    if (normalized == null) {
      return matchedPlan();
    }
    final key = switch (name) {
      'line-color' => DesktopLyricsKeys.lineColor,
      'translation-color' => DesktopLyricsKeys.translationColor,
      'line-outline-color' => DesktopLyricsKeys.lineOutlineColor,
      _ => DesktopLyricsKeys.translationOutlineColor,
    };
    return matchedPlan(write: DesktopLyricsWrite(key, normalized));
  }

  // Qt/src/NativeHudDesktopLyrics.cpp:157-168,207-210 writeOutline
  if (name == 'line-outline' || name == 'translation-outline') {
    final parsed = desktopLyricsParseDouble(argument);
    if (parsed == null) {
      return matchedPlan();
    }
    final clamped = desktopLyricsClampDouble(parsed, 0, DesktopLyricsDefaults.maximumOutline);
    final rounded = desktopLyricsRoundToStep(clamped, DesktopLyricsDefaults.outlineStep);
    final key = name == 'line-outline' ? DesktopLyricsKeys.lineOutline : DesktopLyricsKeys.translationOutline;
    return matchedPlan(write: DesktopLyricsWrite(key, desktopLyricsFormatFixed1(rounded)));
  }

  // Qt/src/NativeHudDesktopLyrics.cpp:211-214
  switch (name) {
    case 'offset-earlier':
      return matchedPlan(playerCommand: DesktopLyricsPlayerCommand.offsetEarlier);
    case 'offset-later':
      return matchedPlan(playerCommand: DesktopLyricsPlayerCommand.offsetLater);
    case 'offset-reset':
      return matchedPlan(playerCommand: DesktopLyricsPlayerCommand.offsetReset);
    case 'offset-global':
      return matchedPlan(playerCommand: DesktopLyricsPlayerCommand.offsetGlobal);
  }

  // Qt/src/NativeHudDesktopLyrics.cpp:215-216 resetAppearance
  if (name == 'reset-style') {
    return matchedPlan(resetsAppearance: true);
  }

  // 未知 name：Qt 不写任何键，但会执行 :218-219 的收尾。
  return DesktopLyricsActionPlan(action: action, name: name, argument: argument);
}

/// back 分支把进入前的设置页滚动位置还原（Qt/src/NativeHudDesktopLyrics.cpp:131-135）。
double desktopLyricsSettingsScrollOnBack({required double returnScroll, required double maximum}) =>
    returnScroll < 0 ? 0 : (returnScroll > maximum ? maximum : returnScroll);

/// 滚动位移后的偏移（Qt/src/NativeHudDesktopLyrics.cpp:139-143 →
/// HudScroll::clampOffset，Qt/src/HudScroll.h:17-19）。
double desktopLyricsScrollAfter({
  required double offset,
  required double delta,
  required double contentHeight,
  required double viewportHeight,
}) {
  final maximum = SettingsRowMetrics.maximumScroll(contentHeight, viewportHeight);
  final next = offset + delta;
  return next < 0 ? 0 : (next > maximum ? maximum : next);
}

// ══════════════════════════════════════════════════════════════════════════════
// 9. 步进器动作串（Qt/src/DesktopLyricsSettingsPage.cpp:171-178,204-213,221-229,243-252）
// ══════════════════════════════════════════════════════════════════════════════

/// 一个步进器的两个动作串。
class DesktopLyricsStepperActions {
  const DesktopLyricsStepperActions({required this.minus, required this.plus});

  final String minus;
  final String plus;

  @override
  bool operator ==(Object other) =>
      other is DesktopLyricsStepperActions && other.minus == minus && other.plus == plus;

  @override
  int get hashCode => Object.hash(minus, plus);

  @override
  String toString() => 'DesktopLyricsStepperActions(' + minus + ', ' + plus + ')';
}

/// 整数步进器：先按 ±step 加减再 clamp（Qt 用 std::max/std::min 各夹一侧）。
DesktopLyricsStepperActions desktopLyricsIntegerStepperActions(
  String actionPrefix, {
  required int current,
  required int minimum,
  required int maximum,
  required int step,
}) {
  final minus = desktopLyricsClampInt(current - step, minimum, maximum);
  final plus = desktopLyricsClampInt(current + step, minimum, maximum);
  return DesktopLyricsStepperActions(
    minus: actionPrefix + minus.toString(),
    plus: actionPrefix + plus.toString(),
  );
}

/// 描边步进器：只 clamp（Qt 的 next 只 clamp，序列化时再保留一位小数）。
DesktopLyricsStepperActions desktopLyricsOutlineStepperActions(String actionPrefix, {required double current}) {
  final minus = desktopLyricsClampDouble(
    current - DesktopLyricsDefaults.outlineStep,
    0,
    DesktopLyricsDefaults.maximumOutline,
  );
  final plus = desktopLyricsClampDouble(
    current + DesktopLyricsDefaults.outlineStep,
    0,
    DesktopLyricsDefaults.maximumOutline,
  );
  return DesktopLyricsStepperActions(
    minus: actionPrefix + desktopLyricsFormatFixed1(minus),
    plus: actionPrefix + desktopLyricsFormatFixed1(plus),
  );
}

/// 偏移块的状态文本（Qt/src/DesktopLyricsSettingsPage.cpp:263-268）。
String desktopLyricsOffsetText(int offsetMs) {
  if (offsetMs == 0) {
    return DesktopLyricsCopy.offsetUncalibrated;
  }
  final direction = offsetMs > 0 ? DesktopLyricsCopy.offsetAheadPrefix : DesktopLyricsCopy.offsetBehindPrefix;
  return direction + desktopLyricsFormatFixed1(offsetMs.abs() / 1000.0) + DesktopLyricsCopy.offsetSecondsSuffix;
}

// ══════════════════════════════════════════════════════════════════════════════
// 10. 页面几何常量（Qt/src/DesktopLyricsSettingsPage.cpp:15-31 与 :84-303）
// ══════════════════════════════════════════════════════════════════════════════

/// 页面常量与派生高度，逐条标 Qt 行号。
class DesktopLyricsPageMetrics {
  const DesktopLyricsPageMetrics._();

  /// Qt/src/DesktopLyricsSettingsPage.cpp:15
  static const double contentInset = 14;

  /// Qt/src/DesktopLyricsSettingsPage.cpp:16
  static const double headerHeight = 40;

  /// Qt/src/DesktopLyricsSettingsPage.cpp:17
  static const double rowHeight = 66;

  /// Qt/src/DesktopLyricsSettingsPage.cpp:18
  static const double rowStep = 76;

  /// Qt/src/DesktopLyricsSettingsPage.cpp:19
  static const double sectionGap = 24;

  /// Qt/src/DesktopLyricsSettingsPage.cpp:20
  static const double controlWidth = 360;

  /// Qt/src/DesktopLyricsSettingsPage.cpp:21
  static const double offsetHeight = 110;

  /// Qt/src/DesktopLyricsSettingsPage.cpp:22
  static const double resetBlockHeight = 90;

  /// Qt/src/DesktopLyricsSettingsPage.cpp:23
  static const double bottomPad = 28;

  /// Qt/src/DesktopLyricsSettingsPage.cpp:25（= 40 + 76*2 + 24 = 216）
  static const double displayHeight = headerHeight + rowStep * 2 + sectionGap;

  /// Qt/src/DesktopLyricsSettingsPage.cpp:26（= 40 + 76*5 + 24 = 444）
  static const double lyricHeight = headerHeight + rowStep * 5 + sectionGap;

  /// Qt/src/DesktopLyricsSettingsPage.cpp:27（= 40 + 76*5 + 24 = 444）
  static const double translationHeight = headerHeight + rowStep * 5 + sectionGap;

  /// Qt/src/DesktopLyricsSettingsPage.cpp:28（= 40 + 110 + 24 = 174）
  static const double syncHeight = headerHeight + offsetHeight + sectionGap;

  /// Qt/src/DesktopLyricsSettingsPage.cpp:29（= 40 + 90 + 24 = 154）
  static const double resetHeight = headerHeight + resetBlockHeight + sectionGap;

  /// Qt/src/DesktopLyricsSettingsPage.cpp:30-31（横屏基线 = 1460）。
  ///
  /// 竖屏重排后行高会变，请用 desktopLyricsContentHeight(reflow) 取当前值。
  static const double contentHeight = displayHeight +
      lyricHeight +
      translationHeight +
      syncHeight +
      resetHeight +
      bottomPad;

  /// Qt/src/DesktopLyricsSettingsPage.cpp:98（控件高 48）
  static const double controlHeight = 48;

  /// Qt/src/DesktopLyricsSettingsPage.cpp:98（控件纵向偏移 y+9）
  static const double controlTopInset = 9;

  /// Qt/src/DesktopLyricsSettingsPage.cpp:85（section 序号：left, y+12, 11pt, regular, 0.05）
  static const double sectionNumberTop = 12;
  static const double sectionNumberSize = 11;
  static const double sectionNumberTracking = 0.05;

  /// Qt/src/DesktopLyricsSettingsPage.cpp:87（section 标题：left+26, y+9, 14pt, demibold, 0.06）
  static const double sectionTitleLeft = 26;
  static const double sectionTitleTop = 9;
  static const double sectionTitleSize = 14;
  static const double sectionTitleTracking = 0.06;

  /// Qt/src/DesktopLyricsSettingsPage.cpp:94（行号：left, y+25, 11pt, regular, 0.04）
  static const double rowIndexTop = 25;
  static const double rowIndexSize = 11;
  static const double rowIndexTracking = 0.04;

  /// Qt/src/DesktopLyricsSettingsPage.cpp:96（行英文标题：left+30, y+10, 11pt, regular, 0.08）
  static const double rowTitleEnLeft = 30;
  static const double rowTitleEnTop = 10;
  static const double rowTitleEnSize = 11;
  static const double rowTitleEnTracking = 0.08;

  /// Qt/src/DesktopLyricsSettingsPage.cpp:97（行中文标题：left+30, y+25, 17pt, demibold, -0.01）
  static const double rowTitleZhLeft = 30;
  static const double rowTitleZhTop = 25;
  static const double rowTitleZhSize = 17;
  static const double rowTitleZhTracking = -0.01;

  /// Qt/src/DesktopLyricsSettingsPage.cpp:106（步进器数值：+16, +15, 15pt, demibold）
  static const double stepperValueLeft = 16;
  static const double stepperValueTop = 15;
  static const double stepperValueSize = 15;

  /// Qt/src/DesktopLyricsSettingsPage.cpp:107-108（减号/加号按钮：32×32，右缩 84 / 40，上缩 8）
  static const double stepperButtonSize = 32;
  static const double stepperButtonTop = 8;
  static const double stepperMinusRightInset = 84;
  static const double stepperPlusRightInset = 40;

  /// Qt/src/DesktopLyricsSettingsPage.cpp:111-112（− 19pt / ＋ 16pt，都是 regular）
  static const double stepperMinusGlyphSize = 19;
  static const double stepperPlusGlyphSize = 16;

  /// Qt/src/DesktopLyricsSettingsPage.cpp:119（段间距 6）
  static const double segmentGap = 6;

  /// Qt/src/DesktopLyricsSettingsPage.cpp:123（段矩形上缩 4、高减 8）
  static const double segmentTopInset = 4;
  static const double segmentHeightInset = 8;

  /// Qt/src/DesktopLyricsSettingsPage.cpp:129（选中态金色竖条宽 3）
  static const double segmentActiveBarWidth = 3;

  /// Qt/src/DesktopLyricsSettingsPage.cpp:132（段文本 13pt，宽减 8）
  static const double segmentTextSize = 13;
  static const double segmentTextInset = 8;

  /// Qt/src/DesktopLyricsSettingsPage.cpp:143（色块起始左缩 6）
  static const double paletteLeftInset = 6;

  /// Qt/src/DesktopLyricsSettingsPage.cpp:146（色块 22×22，纵向居中偏移 -11）
  static const double swatchSize = 22;
  static const double swatchCenterOffset = 11;

  /// Qt/src/DesktopLyricsSettingsPage.cpp:158（色块水平步长 30）
  static const double swatchStride = 30;

  /// Qt/src/DesktopLyricsSettingsPage.cpp:151-154（选中描边环 2px）
  static const double swatchRingWidth = 2;

  /// Qt/src/DesktopLyricsSettingsPage.cpp:261-262（偏移块标题位置）
  static const double offsetTitleEnTop = 10;
  static const double offsetTitleZhTop = 25;

  /// Qt/src/DesktopLyricsSettingsPage.cpp:269（偏移状态：left+30, y+48, 13pt）
  static const double offsetDetailLeft = 30;
  static const double offsetDetailTop = 48;
  static const double offsetDetailSize = 13;

  /// Qt/src/DesktopLyricsSettingsPage.cpp:271（偏移说明：left+30, y+74, 12pt，宽减 30）
  static const double offsetNoteLeft = 30;
  static const double offsetNoteTop = 74;
  static const double offsetNoteSize = 12;
  static const double offsetNoteWidthInset = 30;

  /// Qt/src/DesktopLyricsSettingsPage.cpp:273（偏移按钮容器：left+width-360, y+8）
  static const double offsetControlTopInset = 8;

  /// Qt/src/DesktopLyricsSettingsPage.cpp:280（按钮 84×40，左缩 4，步长 88）
  static const double offsetButtonLeftInset = 4;
  static const double offsetButtonTop = 4;
  static const double offsetButtonWidth = 84;
  static const double offsetButtonHeight = 40;
  static const double offsetButtonStride = 88;

  /// Qt/src/DesktopLyricsSettingsPage.cpp:283（按钮文本 12pt，宽减 8）
  static const double offsetButtonTextSize = 12;
  static const double offsetButtonTextInset = 8;

  /// Qt/src/DesktopLyricsSettingsPage.cpp:292（恢复按钮：left, y+8, 300×48）
  static const double resetButtonTopInset = 8;
  static const double resetButtonWidth = 300;
  static const double resetButtonHeight = 48;

  /// Qt/src/DesktopLyricsSettingsPage.cpp:295（按钮文本：+14, +15, 15pt, regular）
  static const double resetLabelLeftInset = 14;
  static const double resetLabelTopInset = 15;
  static const double resetLabelSize = 15;

  /// Qt/src/DesktopLyricsSettingsPage.cpp:300（说明文字：left+316, y+25, 12pt，宽减 316，最小 60）
  static const double resetNoteLeft = 316;
  static const double resetNoteTop = 25;
  static const double resetNoteSize = 12;
  static const double resetNoteWidthInset = 316;
  static const double resetNoteMinimumWidth = 60;

  /// Qt/src/NativeHudDesktopLyrics.cpp:139（滚动按钮步长 120px）
  static const double scrollButtonStep = 120;

}

/// 面板级几何常量（视口、滚动轨道、滚动按钮）。
class DesktopLyricsPanelMetrics {
  const DesktopLyricsPanelMetrics._();

  /// Qt/src/NativeHud.h:126
  static const double viewportTop = 200;

  /// Qt/src/NativeHud.h:127
  static const double viewportBottom = 820;

  /// Qt/src/NativeHudDesktopLyrics.cpp:36（= 820 - 200 = 620）
  static const double viewportHeight = viewportBottom - viewportTop;

  /// Qt/src/NativeHudDesktopLyrics.cpp:35（左右各缩 40）
  static const double viewportInsetX = 40;

  /// Qt/src/NativeHudDesktopLyrics.cpp:106（轨道右缩 24）
  static const double railInset = 24;

  /// Qt/src/NativeHudDesktopLyrics.cpp:107（轨道上缩 30）
  static const double railTopInset = 30;

  /// Qt/src/NativeHudDesktopLyrics.cpp:108（轨道高度 = 视口高 - 60）
  static const double railBottomInset = 60;

  /// Qt/src/NativeHudDesktopLyrics.cpp:109（轨道宽 3）
  static const double railWidth = 3;

  /// Qt/src/HudScroll.h:51（rail 的 minThumbHeight 默认值 30）
  static const double railMinimumThumbHeight = 30;

  /// Qt/src/NativeHudDesktopLyrics.cpp:117-118（滚动按钮 23×25）
  static const double scrollButtonWidth = 23;
  static const double scrollButtonHeight = 25;

  /// Qt/src/NativeHudDesktopLyrics.cpp:117（按钮左缩 10）
  static const double scrollButtonOffsetX = 10;

  /// Qt/src/NativeHudDesktopLyrics.cpp:117-118（字号 14）
  static const double scrollButtonFontSize = 14;

  /// Qt/src/NativeHudDesktopLyrics.cpp:117
  static const String scrollUpLabel = '↑';

  /// Qt/src/NativeHudDesktopLyrics.cpp:118
  static const String scrollDownLabel = '↓';
}

// ══════════════════════════════════════════════════════════════════════════════
// 11. 竖屏重排（只调宽度与列数，不新增 Qt 里不存在的像素常量）
// ══════════════════════════════════════════════════════════════════════════════

/// 重排参数：控件宽度与各控件的列数。
///
/// Qt 只有横屏基线，这里用 Qt 自己的缩进与步长推导列数：
/// - 色块列数 = floor((控件宽 - 2×6) / 30)（6 = Qt/src/DesktopLyricsSettingsPage.cpp:143 的左缩，
///   30 = :158 的水平步长）；
/// - 偏移按钮列数 = floor((控件宽 - 2×4 + 4) / 88)（4 = :280 的左缩，84×40 按钮、88 步长）；
/// - 纵向复用同样的步长（色块 30、按钮 44 = 40 高 + 4 上缩），不引入新数值。
class DesktopLyricsReflow {
  const DesktopLyricsReflow._({
    required this.controlWidth,
    required this.textPaletteColumns,
    required this.outlinePaletteColumns,
    required this.offsetColumns,
  });

  /// 横屏基线：控件宽 360、两套调色板各一行、偏移按钮一行。
  static const DesktopLyricsReflow landscape = DesktopLyricsReflow._(
    controlWidth: DesktopLyricsPageMetrics.controlWidth,
    textPaletteColumns: 10,
    outlinePaletteColumns: 6,
    offsetColumns: 4,
  );

  /// 按行宽推导（竖屏/窄屏）。行宽小于 360 时控件跟着变窄，列数随之减少。
  factory DesktopLyricsReflow.forRowWidth(double rowWidth) {
    final control = math.min(DesktopLyricsPageMetrics.controlWidth, math.max(0.0, rowWidth));
    final paletteUsable = control - DesktopLyricsPageMetrics.paletteLeftInset * 2;
    final paletteColumns = paletteUsable <= 0
        ? 1
        : math.max(1, (paletteUsable / DesktopLyricsPageMetrics.swatchStride).floor());
    final offsetUsable = control - DesktopLyricsPageMetrics.offsetButtonLeftInset * 2;
    final offsetColumns = offsetUsable <= 0
        ? 1
        : math.max(
            1,
            math.min(
              desktopLyricsOffsetOptions.length,
              ((offsetUsable + (DesktopLyricsPageMetrics.offsetButtonStride -
                          DesktopLyricsPageMetrics.offsetButtonWidth)) /
                      DesktopLyricsPageMetrics.offsetButtonStride)
                  .floor(),
            ),
          );
    return DesktopLyricsReflow._(
      controlWidth: control,
      textPaletteColumns: math.min(paletteColumns, desktopLyricsTextPalette.length),
      outlinePaletteColumns: math.min(paletteColumns, desktopLyricsOutlinePalette.length),
      offsetColumns: offsetColumns,
    );
  }

  /// 控件宽度（≤ 360）。
  final double controlWidth;

  /// 正文/翻译颜色每行几个色块。
  final int textPaletteColumns;

  /// 描边颜色每行几个色块。
  final int outlinePaletteColumns;

  /// 偏移按钮每行几个。
  final int offsetColumns;

  /// 偏移按钮的行数（Qt/src/DesktopLyricsSettingsPage.cpp:279 的四个按钮）。
  int get offsetRows => (desktopLyricsOffsetOptions.length / offsetColumns).ceil();

  /// 偏移块因为换行多出来的高度（44 = 40 高 + 4 上缩，Qt :280）。
  double get offsetExtraHeight =>
      (offsetRows - 1) *
      (DesktopLyricsPageMetrics.offsetButtonHeight + DesktopLyricsPageMetrics.offsetButtonTop);

  /// 某个调色板换行后多出来的高度（30 = Qt :158 的步长）。
  double paletteExtraHeight(int count, int columns) {
    final rows = (count / columns).ceil();
    return (rows - 1) * DesktopLyricsPageMetrics.swatchStride;
  }

  @override
  bool operator ==(Object other) =>
      other is DesktopLyricsReflow &&
      other.controlWidth == controlWidth &&
      other.textPaletteColumns == textPaletteColumns &&
      other.outlinePaletteColumns == outlinePaletteColumns &&
      other.offsetColumns == offsetColumns;

  @override
  int get hashCode =>
      Object.hash(controlWidth, textPaletteColumns, outlinePaletteColumns, offsetColumns);

  @override
  String toString() => 'DesktopLyricsReflow(controlWidth: ' +
      controlWidth.toString() +
      ', textPaletteColumns: ' +
      textPaletteColumns.toString() +
      ', outlinePaletteColumns: ' +
      outlinePaletteColumns.toString() +
      ', offsetColumns: ' +
      offsetColumns.toString() +
      ')';
}

/// 页面内容高度（Qt/src/DesktopLyricsSettingsPage.cpp:25-31 的等价推导）。
///
/// 横屏（reflow = landscape）必须等于 1460；竖屏只按换行增量加高，不删行。
double desktopLyricsContentHeight([DesktopLyricsReflow reflow = DesktopLyricsReflow.landscape]) {
  if (reflow == DesktopLyricsReflow.landscape) {
    return DesktopLyricsPageMetrics.contentHeight;
  }
  final textExtra =
      reflow.paletteExtraHeight(desktopLyricsTextPalette.length, reflow.textPaletteColumns);
  final outlineExtra = reflow.paletteExtraHeight(
      desktopLyricsOutlinePalette.length, reflow.outlinePaletteColumns);
  return 5 * DesktopLyricsPageMetrics.headerHeight +
      5 * DesktopLyricsPageMetrics.sectionGap +
      DesktopLyricsPageMetrics.bottomPad +
      12 * DesktopLyricsPageMetrics.rowStep +
      2 * textExtra +
      2 * outlineExtra +
      DesktopLyricsPageMetrics.offsetHeight +
      reflow.offsetExtraHeight +
      DesktopLyricsPageMetrics.resetBlockHeight;
}

/// measure 的结果（Qt/src/DesktopLyricsSettingsPage.cpp:70-75 的 Layout）。
class DesktopLyricsMeasure {
  const DesktopLyricsMeasure({required this.contentHeight, required this.maximumScroll});

  final double contentHeight;
  final double maximumScroll;

  @override
  String toString() =>
      'DesktopLyricsMeasure(contentHeight: ' + contentHeight.toString() + ', maximumScroll: ' + maximumScroll.toString() + ')';
}

/// Qt/src/DesktopLyricsSettingsPage.cpp:70-75 的等价实现。
///
/// maximumScroll 走 SettingsRowMetrics.maximumScroll，等价 HudScroll::maximum
/// （Qt/src/HudScroll.h:13-15）。
DesktopLyricsMeasure measureDesktopLyrics({
  required double viewportHeight,
  DesktopLyricsReflow reflow = DesktopLyricsReflow.landscape,
}) {
  final contentHeight = desktopLyricsContentHeight(reflow);
  return DesktopLyricsMeasure(
    contentHeight: contentHeight,
    maximumScroll: SettingsRowMetrics.maximumScroll(contentHeight, viewportHeight),
  );
}

// ══════════════════════════════════════════════════════════════════════════════
// 12. 绘制计划：颜色角色与 ops
// ══════════════════════════════════════════════════════════════════════════════

/// 颜色角色，对应 Qt/src/NativeHudDesktopLyrics.cpp:56-62 的七个配色：
/// ink = ink()、muted = fade(ink, 0.55)、faint = fade(ink, 0.12)、line = fade(ink, 0.25)、
/// soft = dark ? {1,1,1,0.05} : {0,0,0,0.04}、gold = {0.835,0.639,0.282,1}、
/// panel = dark ? {0.15,0.15,0.15,1} : {0.929,0.922,0.894,1}。
enum DesktopLyricsInk { ink, muted, faint, line, soft, gold, panel }

/// 绘制用颜色：要么是角色（交给 SettingsPalette 解析），要么是字面色
/// （调色板色块，Qt/src/DesktopLyricsSettingsPage.cpp:60-62 的 colorArray）。
class DesktopLyricsColor {
  const DesktopLyricsColor.role(DesktopLyricsInk this.role) : literal = null;

  const DesktopLyricsColor.literal(SettingsRgba this.literal) : role = null;

  final DesktopLyricsInk? role;
  final SettingsRgba? literal;

  /// 解析成具体 RGBA（paint 阶段调用一次）。
  SettingsRgba resolve(SettingsPalette palette) {
    final literalValue = literal;
    if (literalValue != null) {
      return literalValue;
    }
    switch (role!) {
      case DesktopLyricsInk.ink:
        return palette.ink;
      case DesktopLyricsInk.muted:
        return palette.muted;
      case DesktopLyricsInk.faint:
        return palette.faint;
      case DesktopLyricsInk.line:
        return palette.line;
      case DesktopLyricsInk.soft:
        return palette.soft;
      case DesktopLyricsInk.gold:
        return palette.gold;
      case DesktopLyricsInk.panel:
        return palette.panel;
    }
  }

  @override
  bool operator ==(Object other) =>
      other is DesktopLyricsColor && other.role == role && other.literal == literal;

  @override
  int get hashCode => Object.hash(role, literal);
}

/// 一条绘制/命中指令。顺序即 Qt 的绘制顺序，paint 按序回放。
sealed class DesktopLyricsOp {
  const DesktopLyricsOp();
}

/// Qt 的 canvas.fill(left, top, width, height, color)。
class DesktopLyricsFillOp extends DesktopLyricsOp {
  const DesktopLyricsFillOp(this.left, this.top, this.width, this.height, this.color);

  final double left;
  final double top;
  final double width;
  final double height;
  final DesktopLyricsColor color;

  Rect get rect => Rect.fromLTWH(left, top, width, height);

  @override
  bool operator ==(Object other) =>
      other is DesktopLyricsFillOp &&
      other.left == left &&
      other.top == top &&
      other.width == width &&
      other.height == height &&
      other.color == color;

  @override
  int get hashCode => Object.hash(left, top, width, height, color);

  @override
  String toString() => 'fill(' +
      left.toString() +
      ', ' +
      top.toString() +
      ', ' +
      width.toString() +
      ', ' +
      height.toString() +
      ')';
}

/// Qt 的 canvas.stroke(rect, color)；宿主展开成四条 1px 填充
/// （Qt/src/NativeHudDesktopLyrics.cpp:92-97）。
class DesktopLyricsStrokeOp extends DesktopLyricsOp {
  const DesktopLyricsStrokeOp(this.rect, this.color);

  final Rect rect;
  final DesktopLyricsColor color;

  @override
  bool operator ==(Object other) =>
      other is DesktopLyricsStrokeOp && other.rect == rect && other.color == color;

  @override
  int get hashCode => Object.hash(rect, color);

  @override
  String toString() => 'stroke(' + rect.toString() + ')';
}

/// Qt 的 canvas.text(value, left, top, size, weight, tracking, color)。
///
/// fitMaxWidth 非空时先过 canvas.fit(value, size, fitMaxWidth, weight)
/// （Qt/src/DesktopLyricsSettingsPage.cpp:132、:271、:283、:300）。
class DesktopLyricsTextOp extends DesktopLyricsOp {
  const DesktopLyricsTextOp({
    required this.value,
    required this.left,
    required this.top,
    required this.size,
    required this.weight,
    required this.tracking,
    required this.color,
    this.fitMaxWidth,
  });

  final String value;
  final double left;
  final double top;
  final double size;
  final SettingsFontWeight weight;
  final double tracking;
  final DesktopLyricsColor color;
  final double? fitMaxWidth;

  @override
  bool operator ==(Object other) =>
      other is DesktopLyricsTextOp &&
      other.value == value &&
      other.left == left &&
      other.top == top &&
      other.size == size &&
      other.weight == weight &&
      other.tracking == tracking &&
      other.color == color &&
      other.fitMaxWidth == fitMaxWidth;

  @override
  int get hashCode => Object.hash(value, left, top, size, weight, tracking, color, fitMaxWidth);

  @override
  String toString() => 'text(' + value + ' @ ' + left.toString() + ',' + top.toString() + ')';
}

/// Qt 的 canvas.centered(value, x, cy, size, weight, horizontal)。
///
/// 没有颜色参数：Qt 的 Canvas::centered 同样只吃当前色（见「已知边界」）。
class DesktopLyricsCenteredOp extends DesktopLyricsOp {
  const DesktopLyricsCenteredOp({
    required this.value,
    required this.x,
    required this.cy,
    required this.size,
    required this.weight,
    required this.horizontal,
    this.fitMaxWidth,
  });

  final String value;
  final double x;
  final double cy;
  final double size;
  final SettingsFontWeight weight;
  final bool horizontal;
  final double? fitMaxWidth;

  @override
  bool operator ==(Object other) =>
      other is DesktopLyricsCenteredOp &&
      other.value == value &&
      other.x == x &&
      other.cy == cy &&
      other.size == size &&
      other.weight == weight &&
      other.horizontal == horizontal &&
      other.fitMaxWidth == fitMaxWidth;

  @override
  int get hashCode => Object.hash(value, x, cy, size, weight, horizontal, fitMaxWidth);

  @override
  String toString() => 'centered(' + value + ' @ ' + x.toString() + ',' + cy.toString() + ')';
}

/// Qt 的 canvas.hit(left, top, width, height, action, label)。
class DesktopLyricsHitOp extends DesktopLyricsOp {
  const DesktopLyricsHitOp(this.rect, this.action, this.label);

  final Rect rect;
  final String action;
  final String label;

  @override
  bool operator ==(Object other) =>
      other is DesktopLyricsHitOp &&
      other.rect == rect &&
      other.action == action &&
      other.label == label;

  @override
  int get hashCode => Object.hash(rect, action, label);

  @override
  String toString() => 'hit(' + action + ' / ' + label + ')';
}

/// 控件类型（Qt/src/DesktopLyricsSettingsPage.cpp:102-160 的三个 lambda + SYNC/RESET 块）。
enum DesktopLyricsControlKind { segments, stepper, palette, offsetButtons, resetButton }

/// 一个 section 的结构信息（用于逐条断言序号、标题、纵向区间与下划线）。
class DesktopLyricsSectionInfo {
  const DesktopLyricsSectionInfo({
    required this.number,
    required this.titleEn,
    required this.titleZh,
    required this.top,
    required this.height,
    required this.underline,
  });

  final int number;
  final String titleEn;
  final String titleZh;
  final double top;
  final double height;
  final Rect underline;

  @override
  String toString() => 'section(' + number.toString() + ': ' + titleEn + ' / ' + titleZh + ')';
}

/// 一行/一块的结构信息（12 个带行号的行 + SYNC/RESET 两块，共 14 条）。
class DesktopLyricsRowInfo {
  const DesktopLyricsRowInfo({
    required this.rowNumber,
    required this.titleEn,
    required this.titleZh,
    required this.kind,
    required this.value,
    required this.actions,
    required this.top,
    required this.height,
    required this.control,
  });

  /// 1 基行号；SYNC / RESET 块为 null（Qt 不给它们编号，:259-303）。
  final int? rowNumber;
  final String titleEn;
  final String titleZh;
  final DesktopLyricsControlKind kind;

  /// 该行展示的值文本（步进器数值、偏移状态文本、按钮文字）。
  final String value;

  /// 该行产生的命中动作，顺序同 Qt。
  final List<String> actions;
  final double top;
  final double height;

  /// 控件矩形（步进器/段控/调色板/偏移容器/恢复按钮）。
  final Rect? control;

  @override
  String toString() => 'row(' +
      (rowNumber?.toString() ?? '--') +
      ': ' +
      titleEn +
      ' / ' +
      titleZh +
      ', ' +
      kind.name +
      ')';
}

/// 页面布局与绘制计划：paint 只需按 ops 顺序回放。
class DesktopLyricsLayout {
  const DesktopLyricsLayout({
    required this.viewport,
    required this.left,
    required this.width,
    required this.top,
    required this.contentHeight,
    required this.maximumScroll,
    required this.ops,
    required this.sections,
    required this.rows,
  });

  final Rect viewport;

  /// 内容左边界（viewport.left + 14，Qt :79）。
  final double left;

  /// 内容宽度（viewport.width - 28，Qt :80）。
  final double width;

  /// 第一行起始 y（viewport.top - scroll，Qt :78）。
  final double top;

  final double contentHeight;
  final double maximumScroll;
  final List<DesktopLyricsOp> ops;
  final List<DesktopLyricsSectionInfo> sections;
  final List<DesktopLyricsRowInfo> rows;

  Iterable<DesktopLyricsFillOp> get fills => ops.whereType<DesktopLyricsFillOp>();

  Iterable<DesktopLyricsStrokeOp> get strokes => ops.whereType<DesktopLyricsStrokeOp>();

  Iterable<DesktopLyricsTextOp> get texts => ops.whereType<DesktopLyricsTextOp>();

  Iterable<DesktopLyricsCenteredOp> get centered => ops.whereType<DesktopLyricsCenteredOp>();

  Iterable<DesktopLyricsHitOp> get hitOps => ops.whereType<DesktopLyricsHitOp>();

  /// 命中区列表（未裁剪；需要视口裁剪时用 desktopLyricsClipHits）。
  List<SettingsHitRegion> get hitRegions =>
      <SettingsHitRegion>[for (final op in hitOps) SettingsHitRegion(op.rect, op.action, op.label)];

  /// 全部命中动作，顺序同 Qt 的 canvas.hit 调用顺序。
  List<String> get actions => <String>[for (final op in hitOps) op.action];

  /// 全部文本值，顺序同 Qt 的 canvas.text 调用顺序。
  List<String> get textValues => <String>[for (final op in texts) op.value];

  DesktopLyricsHitOp? hitFor(String action) {
    for (final op in hitOps) {
      if (op.action == action) {
        return op;
      }
    }
    return null;
  }

  bool hasHit(String action) => hitFor(action) != null;

  DesktopLyricsRowInfo? rowWithTitle(String titleEn) {
    for (final row in rows) {
      if (row.titleEn == titleEn) {
        return row;
      }
    }
    return null;
  }

  @override
  String toString() => 'DesktopLyricsLayout(' +
      sections.length.toString() +
      ' sections, ' +
      rows.length.toString() +
      ' rows, contentHeight: ' +
      contentHeight.toString() +
      ')';
}

String _twoDigits(int value) => value.toString().padLeft(2, '0');

// ══════════════════════════════════════════════════════════════════════════════
// 13. 布局（Qt/src/DesktopLyricsSettingsPage.cpp:77-303 的纯几何版）
// ══════════════════════════════════════════════════════════════════════════════

/// 生成整页的绘制计划、命中计划与结构信息。
///
/// 顺序逐字对应 Qt/src/DesktopLyricsSettingsPage.cpp:162-303：
/// DISPLAY（ENABLED、OPACITY）→ LYRIC（SIZE、WEIGHT、COLOR、OUTLINE、OUTLINE COLOR）
/// → TRANSLATION（同五项）→ SYNC（OFFSET 块）→ RESET（恢复默认样式块）。
///
/// reflow 为 null 时用横屏基线（Qt 原始像素）；竖屏传
/// DesktopLyricsReflow.forRowWidth(rowWidth)，只改宽度与列数，不删行。
DesktopLyricsLayout layoutDesktopLyricsSettings({
  required Rect viewport,
  required double scroll,
  required bool enabled,
  required DesktopLyricsAppearance appearance,
  required int offsetMs,
  DesktopLyricsReflow? reflow,
}) {
  final effectiveReflow = reflow ?? DesktopLyricsReflow.landscape;
  final left = viewport.left + DesktopLyricsPageMetrics.contentInset;
  final width = viewport.width - DesktopLyricsPageMetrics.contentInset * 2;
  final ops = <DesktopLyricsOp>[];
  final sections = <DesktopLyricsSectionInfo>[];
  final rows = <DesktopLyricsRowInfo>[];
  var y = viewport.top - scroll;
  var sectionNumber = 0;
  var rowNumber = 0;

  const inkColor = DesktopLyricsColor.role(DesktopLyricsInk.ink);
  const mutedColor = DesktopLyricsColor.role(DesktopLyricsInk.muted);
  const lineColor = DesktopLyricsColor.role(DesktopLyricsInk.line);
  const softColor = DesktopLyricsColor.role(DesktopLyricsInk.soft);
  const goldColor = DesktopLyricsColor.role(DesktopLyricsInk.gold);

  // Qt :84-90
  void addSection(String titleEn, String titleZh, void Function() body) {
    final sectionTop = y;
    sectionNumber += 1;
    ops.add(DesktopLyricsTextOp(
      value: _twoDigits(sectionNumber),
      left: left,
      top: y + DesktopLyricsPageMetrics.sectionNumberTop,
      size: DesktopLyricsPageMetrics.sectionNumberSize,
      weight: SettingsFontWeight.regular,
      tracking: DesktopLyricsPageMetrics.sectionNumberTracking,
      color: mutedColor,
    ));
    ops.add(DesktopLyricsTextOp(
      value: titleEn + ' / ' + titleZh,
      left: left + DesktopLyricsPageMetrics.sectionTitleLeft,
      top: y + DesktopLyricsPageMetrics.sectionTitleTop,
      size: DesktopLyricsPageMetrics.sectionTitleSize,
      weight: SettingsFontWeight.demibold,
      tracking: DesktopLyricsPageMetrics.sectionTitleTracking,
      color: inkColor,
    ));
    ops.add(DesktopLyricsFillOp(
      left,
      y + DesktopLyricsPageMetrics.headerHeight - 1,
      width,
      1,
      lineColor,
    ));
    y += DesktopLyricsPageMetrics.headerHeight;
    body();
    y += DesktopLyricsPageMetrics.sectionGap;
    sections.add(DesktopLyricsSectionInfo(
      number: sectionNumber,
      titleEn: titleEn,
      titleZh: titleZh,
      top: sectionTop,
      height: y - sectionTop,
      underline: Rect.fromLTWH(
        left,
        sectionTop + DesktopLyricsPageMetrics.headerHeight - 1,
        width,
        1,
      ),
    ));
  }

  // Qt :92-100
  void addRow({
    required String titleEn,
    required String titleZh,
    required DesktopLyricsControlKind kind,
    required String value,
    required void Function(Rect control) body,
    double extraHeight = 0,
  }) {
    final rowTop = y;
    rowNumber += 1;
    final effectiveRowHeight = DesktopLyricsPageMetrics.rowHeight + extraHeight;
    ops.add(DesktopLyricsFillOp(left, rowTop + effectiveRowHeight - 1, width, 1, lineColor));
    ops.add(DesktopLyricsTextOp(
      value: _twoDigits(rowNumber),
      left: left,
      top: rowTop + DesktopLyricsPageMetrics.rowIndexTop,
      size: DesktopLyricsPageMetrics.rowIndexSize,
      weight: SettingsFontWeight.regular,
      tracking: DesktopLyricsPageMetrics.rowIndexTracking,
      color: mutedColor,
    ));
    ops.add(DesktopLyricsTextOp(
      value: titleEn,
      left: left + DesktopLyricsPageMetrics.rowTitleEnLeft,
      top: rowTop + DesktopLyricsPageMetrics.rowTitleEnTop,
      size: DesktopLyricsPageMetrics.rowTitleEnSize,
      weight: SettingsFontWeight.regular,
      tracking: DesktopLyricsPageMetrics.rowTitleEnTracking,
      color: mutedColor,
    ));
    ops.add(DesktopLyricsTextOp(
      value: titleZh,
      left: left + DesktopLyricsPageMetrics.rowTitleZhLeft,
      top: rowTop + DesktopLyricsPageMetrics.rowTitleZhTop,
      size: DesktopLyricsPageMetrics.rowTitleZhSize,
      weight: SettingsFontWeight.demibold,
      tracking: DesktopLyricsPageMetrics.rowTitleZhTracking,
      color: inkColor,
    ));
    final control = Rect.fromLTWH(
      left + width - effectiveReflow.controlWidth,
      rowTop + DesktopLyricsPageMetrics.controlTopInset,
      effectiveReflow.controlWidth,
      DesktopLyricsPageMetrics.controlHeight + extraHeight,
    );
    final hitsBefore = ops.length;
    body(control);
    final rowActions = <String>[
      for (final op in ops.skip(hitsBefore))
        if (op is DesktopLyricsHitOp) op.action,
    ];
    rows.add(DesktopLyricsRowInfo(
      rowNumber: rowNumber,
      titleEn: titleEn,
      titleZh: titleZh,
      kind: kind,
      value: value,
      actions: rowActions,
      top: rowTop,
      height: effectiveRowHeight,
      control: control,
    ));
    y += DesktopLyricsPageMetrics.rowStep + extraHeight;
  }

  // Qt :102-115
  void addStepper(
    Rect control,
    String valueText,
    DesktopLyricsStepperActions stepperActions,
    String label,
  ) {
    ops.add(DesktopLyricsFillOp(control.left, control.top, control.width, control.height, softColor));
    ops.add(DesktopLyricsStrokeOp(control, lineColor));
    ops.add(DesktopLyricsTextOp(
      value: valueText,
      left: control.left + DesktopLyricsPageMetrics.stepperValueLeft,
      top: control.top + DesktopLyricsPageMetrics.stepperValueTop,
      size: DesktopLyricsPageMetrics.stepperValueSize,
      weight: SettingsFontWeight.demibold,
      tracking: 0,
      color: inkColor,
    ));
    final minusRect = Rect.fromLTWH(
      control.right - DesktopLyricsPageMetrics.stepperMinusRightInset,
      control.top + DesktopLyricsPageMetrics.stepperButtonTop,
      DesktopLyricsPageMetrics.stepperButtonSize,
      DesktopLyricsPageMetrics.stepperButtonSize,
    );
    final plusRect = Rect.fromLTWH(
      control.right - DesktopLyricsPageMetrics.stepperPlusRightInset,
      control.top + DesktopLyricsPageMetrics.stepperButtonTop,
      DesktopLyricsPageMetrics.stepperButtonSize,
      DesktopLyricsPageMetrics.stepperButtonSize,
    );
    ops.add(DesktopLyricsStrokeOp(minusRect, lineColor));
    ops.add(DesktopLyricsStrokeOp(plusRect, lineColor));
    ops.add(DesktopLyricsCenteredOp(
      value: '−',
      x: minusRect.center.dx,
      cy: minusRect.center.dy,
      size: DesktopLyricsPageMetrics.stepperMinusGlyphSize,
      weight: SettingsFontWeight.regular,
      horizontal: true,
    ));
    ops.add(DesktopLyricsCenteredOp(
      value: '＋',
      x: plusRect.center.dx,
      cy: plusRect.center.dy,
      size: DesktopLyricsPageMetrics.stepperPlusGlyphSize,
      weight: SettingsFontWeight.regular,
      horizontal: true,
    ));
    ops.add(DesktopLyricsHitOp(minusRect, stepperActions.minus, label));
    ops.add(DesktopLyricsHitOp(plusRect, stepperActions.plus, label));
  }

  // Qt :117-137
  void addSegments(
    Rect control,
    List<DesktopLyricsOption> options,
    String current,
    String actionPrefix,
    String label,
  ) {
    final count = options.length;
    final segmentWidth =
        (control.width - DesktopLyricsPageMetrics.segmentGap * math.max(0, count - 1)) /
            math.max(1, count);
    for (var index = 0; index < count; index += 1) {
      final rect = Rect.fromLTWH(
        control.left + index * (segmentWidth + DesktopLyricsPageMetrics.segmentGap),
        control.top + DesktopLyricsPageMetrics.segmentTopInset,
        segmentWidth,
        control.height - DesktopLyricsPageMetrics.segmentHeightInset,
      );
      ops.add(DesktopLyricsFillOp(rect.left, rect.top, rect.width, rect.height, softColor));
      ops.add(DesktopLyricsStrokeOp(rect, lineColor));
      final active = options[index].value == current;
      if (active) {
        ops.add(DesktopLyricsFillOp(
          rect.left,
          rect.top,
          DesktopLyricsPageMetrics.segmentActiveBarWidth,
          rect.height,
          goldColor,
        ));
      }
      final weight = active ? SettingsFontWeight.demibold : SettingsFontWeight.regular;
      ops.add(DesktopLyricsCenteredOp(
        value: options[index].label,
        x: rect.center.dx,
        cy: rect.center.dy,
        size: DesktopLyricsPageMetrics.segmentTextSize,
        weight: weight,
        horizontal: true,
        fitMaxWidth: rect.width - DesktopLyricsPageMetrics.segmentTextInset,
      ));
      ops.add(DesktopLyricsHitOp(
        rect,
        DesktopLyricsActions.actionFor(actionPrefix, options[index].value),
        label,
      ));
    }
  }

  // Qt :139-160
  void addPalette(
    Rect control,
    List<DesktopLyricsOption> entries,
    String current,
    String actionPrefix,
    int columns,
  ) {
    ops.add(DesktopLyricsFillOp(control.left, control.top, control.width, control.height, softColor));
    ops.add(DesktopLyricsStrokeOp(control, lineColor));
    for (var index = 0; index < entries.length; index += 1) {
      final column = index % columns;
      final row = index ~/ columns;
      final swatchLeft = control.left +
          DesktopLyricsPageMetrics.paletteLeftInset +
          column * DesktopLyricsPageMetrics.swatchStride;
      final swatchTop = control.center.dy -
          DesktopLyricsPageMetrics.swatchCenterOffset +
          row * DesktopLyricsPageMetrics.swatchStride;
      final swatch = Rect.fromLTWH(
        swatchLeft,
        swatchTop,
        DesktopLyricsPageMetrics.swatchSize,
        DesktopLyricsPageMetrics.swatchSize,
      );
      ops.add(DesktopLyricsFillOp(
        swatch.left,
        swatch.top,
        swatch.width,
        swatch.height,
        DesktopLyricsColor.literal(desktopLyricsRgbaFromHex(entries[index].value)),
      ));
      ops.add(DesktopLyricsStrokeOp(swatch, lineColor));
      final value = entries[index].value.toLowerCase();
      if (value == current) {
        final ring = DesktopLyricsPageMetrics.swatchRingWidth;
        ops.add(DesktopLyricsFillOp(
            swatch.left - ring, swatch.top - ring, swatch.width + ring * 2, ring, goldColor));
        ops.add(DesktopLyricsFillOp(
            swatch.left - ring, swatch.bottom, swatch.width + ring * 2, ring, goldColor));
        ops.add(DesktopLyricsFillOp(swatch.left - ring, swatch.top, ring, swatch.height, goldColor));
        ops.add(DesktopLyricsFillOp(swatch.right, swatch.top, ring, swatch.height, goldColor));
      }
      ops.add(DesktopLyricsHitOp(
        swatch,
        DesktopLyricsActions.actionFor(actionPrefix, value),
        entries[index].label,
      ));
    }
  }

  final textPaletteExtra = effectiveReflow.paletteExtraHeight(
      desktopLyricsTextPalette.length, effectiveReflow.textPaletteColumns);
  final outlinePaletteExtra = effectiveReflow.paletteExtraHeight(
      desktopLyricsOutlinePalette.length, effectiveReflow.outlinePaletteColumns);

  // ── DISPLAY（Qt :162-179）─────────────────────────────────────────────────
  addSection(DesktopLyricsCopy.sectionDisplayEn, DesktopLyricsCopy.sectionDisplayZh, () {
    final enabledValue = enabled ? 'on' : 'off';
    addRow(
      titleEn: 'ENABLED',
      titleZh: '显示桌面歌词',
      kind: DesktopLyricsControlKind.segments,
      value: enabledValue,
      body: (control) => addSegments(
        control,
        desktopLyricsToggleOptions,
        enabledValue,
        DesktopLyricsActions.enabledPrefix,
        '显示桌面歌词',
      ),
    );
    final opacityText = appearance.opacity.toString() + '%';
    addRow(
      titleEn: 'OPACITY',
      titleZh: '整体透明度',
      kind: DesktopLyricsControlKind.stepper,
      value: opacityText,
      body: (control) => addStepper(
        control,
        opacityText,
        desktopLyricsIntegerStepperActions(
          DesktopLyricsActions.opacityPrefix,
          current: appearance.opacity,
          minimum: DesktopLyricsDefaults.minimumOpacity,
          maximum: DesktopLyricsDefaults.maximumOpacity,
          step: 5,
        ),
        '整体透明度',
      ),
    );
  });

  // ── LYRIC（Qt :181-218）───────────────────────────────────────────────────
  addSection(DesktopLyricsCopy.sectionLyricEn, DesktopLyricsCopy.sectionLyricZh, () {
    final sizeText = appearance.lineSize.toString() + ' px';
    addRow(
      titleEn: 'SIZE',
      titleZh: '字号',
      kind: DesktopLyricsControlKind.stepper,
      value: sizeText,
      body: (control) => addStepper(
        control,
        sizeText,
        desktopLyricsIntegerStepperActions(
          DesktopLyricsActions.lineSizePrefix,
          current: appearance.lineSize,
          minimum: DesktopLyricsDefaults.minimumLineSize,
          maximum: DesktopLyricsDefaults.maximumLineSize,
          step: 2,
        ),
        '正文字号',
      ),
    );
    addRow(
      titleEn: 'WEIGHT',
      titleZh: '字重',
      kind: DesktopLyricsControlKind.segments,
      value: appearance.lineWeight,
      body: (control) => addSegments(
        control,
        desktopLyricsWeightOptions,
        appearance.lineWeight,
        DesktopLyricsActions.lineWeightPrefix,
        '正文字重',
      ),
    );
    addRow(
      titleEn: 'COLOR',
      titleZh: '颜色',
      kind: DesktopLyricsControlKind.palette,
      value: appearance.lineColor,
      extraHeight: textPaletteExtra,
      body: (control) => addPalette(
        control,
        desktopLyricsTextPalette,
        appearance.lineColor,
        DesktopLyricsActions.lineColorPrefix,
        effectiveReflow.textPaletteColumns,
      ),
    );
    final outlineText = desktopLyricsFormatFixed1(appearance.lineOutline) + ' px';
    addRow(
      titleEn: 'OUTLINE',
      titleZh: '描边',
      kind: DesktopLyricsControlKind.stepper,
      value: outlineText,
      body: (control) => addStepper(
        control,
        outlineText,
        desktopLyricsOutlineStepperActions(
          DesktopLyricsActions.lineOutlinePrefix,
          current: appearance.lineOutline,
        ),
        '正文描边',
      ),
    );
    addRow(
      titleEn: 'OUTLINE COLOR',
      titleZh: '描边颜色',
      kind: DesktopLyricsControlKind.palette,
      value: appearance.lineOutlineColor,
      extraHeight: outlinePaletteExtra,
      body: (control) => addPalette(
        control,
        desktopLyricsOutlinePalette,
        appearance.lineOutlineColor,
        DesktopLyricsActions.lineOutlineColorPrefix,
        effectiveReflow.outlinePaletteColumns,
      ),
    );
  });

  // ── TRANSLATION（Qt :220-257）─────────────────────────────────────────────
  addSection(DesktopLyricsCopy.sectionTranslationEn, DesktopLyricsCopy.sectionTranslationZh, () {
    final sizeText = appearance.translationSize.toString() + ' px';
    addRow(
      titleEn: 'SIZE',
      titleZh: '字号',
      kind: DesktopLyricsControlKind.stepper,
      value: sizeText,
      body: (control) => addStepper(
        control,
        sizeText,
        desktopLyricsIntegerStepperActions(
          DesktopLyricsActions.translationSizePrefix,
          current: appearance.translationSize,
          minimum: DesktopLyricsDefaults.minimumTranslationSize,
          maximum: DesktopLyricsDefaults.maximumTranslationSize,
          step: 2,
        ),
        '翻译字号',
      ),
    );
    addRow(
      titleEn: 'WEIGHT',
      titleZh: '字重',
      kind: DesktopLyricsControlKind.segments,
      value: appearance.translationWeight,
      body: (control) => addSegments(
        control,
        desktopLyricsWeightOptions,
        appearance.translationWeight,
        DesktopLyricsActions.translationWeightPrefix,
        '翻译字重',
      ),
    );
    addRow(
      titleEn: 'COLOR',
      titleZh: '颜色',
      kind: DesktopLyricsControlKind.palette,
      value: appearance.translationColor,
      extraHeight: textPaletteExtra,
      body: (control) => addPalette(
        control,
        desktopLyricsTextPalette,
        appearance.translationColor,
        DesktopLyricsActions.translationColorPrefix,
        effectiveReflow.textPaletteColumns,
      ),
    );
    final outlineText = desktopLyricsFormatFixed1(appearance.translationOutline) + ' px';
    addRow(
      titleEn: 'OUTLINE',
      titleZh: '描边',
      kind: DesktopLyricsControlKind.stepper,
      value: outlineText,
      body: (control) => addStepper(
        control,
        outlineText,
        desktopLyricsOutlineStepperActions(
          DesktopLyricsActions.translationOutlinePrefix,
          current: appearance.translationOutline,
        ),
        '翻译描边',
      ),
    );
    addRow(
      titleEn: 'OUTLINE COLOR',
      titleZh: '描边颜色',
      kind: DesktopLyricsControlKind.palette,
      value: appearance.translationOutlineColor,
      extraHeight: outlinePaletteExtra,
      body: (control) => addPalette(
        control,
        desktopLyricsOutlinePalette,
        appearance.translationOutlineColor,
        DesktopLyricsActions.translationOutlineColorPrefix,
        effectiveReflow.outlinePaletteColumns,
      ),
    );
  });

  // ── SYNC（Qt :259-289）────────────────────────────────────────────────────
  addSection(DesktopLyricsCopy.sectionSyncEn, DesktopLyricsCopy.sectionSyncZh, () {
    final blockTop = y;
    final blockHeight = DesktopLyricsPageMetrics.offsetHeight + effectiveReflow.offsetExtraHeight;
    final offsetText = desktopLyricsOffsetText(offsetMs);
    ops.add(DesktopLyricsFillOp(left, blockTop + blockHeight - 1, width, 1, lineColor));
    ops.add(DesktopLyricsTextOp(
      value: DesktopLyricsCopy.offsetTitleEn,
      left: left,
      top: blockTop + DesktopLyricsPageMetrics.offsetTitleEnTop,
      size: DesktopLyricsPageMetrics.rowTitleEnSize,
      weight: SettingsFontWeight.regular,
      tracking: DesktopLyricsPageMetrics.rowTitleEnTracking,
      color: mutedColor,
    ));
    ops.add(DesktopLyricsTextOp(
      value: DesktopLyricsCopy.offsetTitleZh,
      left: left + DesktopLyricsPageMetrics.rowTitleZhLeft,
      top: blockTop + DesktopLyricsPageMetrics.offsetTitleZhTop,
      size: DesktopLyricsPageMetrics.rowTitleZhSize,
      weight: SettingsFontWeight.demibold,
      tracking: DesktopLyricsPageMetrics.rowTitleZhTracking,
      color: inkColor,
    ));
    ops.add(DesktopLyricsTextOp(
      value: offsetText,
      left: left + DesktopLyricsPageMetrics.offsetDetailLeft,
      top: blockTop + DesktopLyricsPageMetrics.offsetDetailTop,
      size: DesktopLyricsPageMetrics.offsetDetailSize,
      weight: SettingsFontWeight.regular,
      tracking: 0,
      color: mutedColor,
    ));
    ops.add(DesktopLyricsTextOp(
      value: DesktopLyricsCopy.offsetNote,
      left: left + DesktopLyricsPageMetrics.offsetNoteLeft,
      top: blockTop + DesktopLyricsPageMetrics.offsetNoteTop,
      size: DesktopLyricsPageMetrics.offsetNoteSize,
      weight: SettingsFontWeight.regular,
      tracking: 0,
      color: mutedColor,
      fitMaxWidth: width - DesktopLyricsPageMetrics.offsetNoteWidthInset,
    ));
    final control = Rect.fromLTWH(
      left + width - effectiveReflow.controlWidth,
      blockTop + DesktopLyricsPageMetrics.offsetControlTopInset,
      effectiveReflow.controlWidth,
      DesktopLyricsPageMetrics.controlHeight + effectiveReflow.offsetExtraHeight,
    );
    final blockActions = <String>[];
    for (var index = 0; index < desktopLyricsOffsetOptions.length; index += 1) {
      final column = index % effectiveReflow.offsetColumns;
      final row = index ~/ effectiveReflow.offsetColumns;
      final rect = Rect.fromLTWH(
        control.left +
            DesktopLyricsPageMetrics.offsetButtonLeftInset +
            column * DesktopLyricsPageMetrics.offsetButtonStride,
        control.top +
            DesktopLyricsPageMetrics.offsetButtonTop +
            row *
                (DesktopLyricsPageMetrics.offsetButtonHeight +
                    DesktopLyricsPageMetrics.offsetButtonTop),
        DesktopLyricsPageMetrics.offsetButtonWidth,
        DesktopLyricsPageMetrics.offsetButtonHeight,
      );
      ops.add(DesktopLyricsFillOp(rect.left, rect.top, rect.width, rect.height, softColor));
      ops.add(DesktopLyricsStrokeOp(rect, lineColor));
      ops.add(DesktopLyricsCenteredOp(
        value: desktopLyricsOffsetOptions[index].label,
        x: rect.center.dx,
        cy: rect.center.dy,
        size: DesktopLyricsPageMetrics.offsetButtonTextSize,
        weight: SettingsFontWeight.regular,
        horizontal: true,
        fitMaxWidth: rect.width - DesktopLyricsPageMetrics.offsetButtonTextInset,
      ));
      ops.add(DesktopLyricsHitOp(
        rect,
        desktopLyricsOffsetOptions[index].value,
        desktopLyricsOffsetOptions[index].label,
      ));
      blockActions.add(desktopLyricsOffsetOptions[index].value);
    }
    rows.add(DesktopLyricsRowInfo(
      rowNumber: null,
      titleEn: DesktopLyricsCopy.offsetTitleEn,
      titleZh: DesktopLyricsCopy.offsetTitleZh,
      kind: DesktopLyricsControlKind.offsetButtons,
      value: offsetText,
      actions: blockActions,
      top: blockTop,
      height: blockHeight,
      control: control,
    ));
    y += blockHeight;
  });

  // ── RESET（Qt :291-303）───────────────────────────────────────────────────
  addSection(DesktopLyricsCopy.sectionResetEn, DesktopLyricsCopy.sectionResetZh, () {
    final blockTop = y;
    final resetRect = Rect.fromLTWH(
      left,
      blockTop + DesktopLyricsPageMetrics.resetButtonTopInset,
      DesktopLyricsPageMetrics.resetButtonWidth,
      DesktopLyricsPageMetrics.resetButtonHeight,
    );
    ops.add(
        DesktopLyricsFillOp(resetRect.left, resetRect.top, resetRect.width, resetRect.height, softColor));
    ops.add(DesktopLyricsStrokeOp(resetRect, lineColor));
    ops.add(DesktopLyricsTextOp(
      value: DesktopLyricsCopy.resetLabel,
      left: resetRect.left + DesktopLyricsPageMetrics.resetLabelLeftInset,
      top: resetRect.top + DesktopLyricsPageMetrics.resetLabelTopInset,
      size: DesktopLyricsPageMetrics.resetLabelSize,
      weight: SettingsFontWeight.regular,
      tracking: 0,
      color: inkColor,
    ));
    ops.add(DesktopLyricsHitOp(resetRect, DesktopLyricsActions.resetStyle, DesktopLyricsCopy.resetLabel));
    ops.add(DesktopLyricsTextOp(
      value: DesktopLyricsCopy.resetNote,
      left: left + DesktopLyricsPageMetrics.resetNoteLeft,
      top: blockTop + DesktopLyricsPageMetrics.resetNoteTop,
      size: DesktopLyricsPageMetrics.resetNoteSize,
      weight: SettingsFontWeight.regular,
      tracking: 0,
      color: mutedColor,
      fitMaxWidth: math.max(
        DesktopLyricsPageMetrics.resetNoteMinimumWidth,
        width - DesktopLyricsPageMetrics.resetNoteWidthInset,
      ),
    ));
    rows.add(DesktopLyricsRowInfo(
      rowNumber: null,
      titleEn: '',
      titleZh: '',
      kind: DesktopLyricsControlKind.resetButton,
      value: DesktopLyricsCopy.resetLabel,
      actions: const <String>[DesktopLyricsActions.resetStyle],
      top: blockTop,
      height: DesktopLyricsPageMetrics.resetBlockHeight,
      control: resetRect,
    ));
    y += DesktopLyricsPageMetrics.resetBlockHeight;
  });

  // Qt 的 scroll 上限用的是常量 ContentHeight（Qt/src/DesktopLyricsSettingsPage.cpp:30-31），
  // 它比最后一行的底部多出 BottomPad 28（:23）。横屏且行高未增时这里必须等于 1460。
  final contentHeight =
      y - (viewport.top - scroll) + DesktopLyricsPageMetrics.bottomPad;
  return DesktopLyricsLayout(
    viewport: viewport,
    left: left,
    width: width,
    top: viewport.top - scroll,
    contentHeight: contentHeight,
    maximumScroll: SettingsRowMetrics.maximumScroll(contentHeight, viewport.height),
    ops: List<DesktopLyricsOp>.unmodifiable(ops),
    sections: List<DesktopLyricsSectionInfo>.unmodifiable(sections),
    rows: List<DesktopLyricsRowInfo>.unmodifiable(rows),
  );
}

// ══════════════════════════════════════════════════════════════════════════════
// 14. 绘制（按计划回放，Qt/src/DesktopLyricsSettingsPage.cpp:77-303 的 Canvas 侧）
// ══════════════════════════════════════════════════════════════════════════════

/// 把布局计划回放到 SettingsCanvas，并返回命中区。
///
/// clipTo 非空时对命中区调用 clipSettingsHits（等价 HudScroll::clipHits，
/// Qt/src/HudScroll.h:67-86）。
List<SettingsHitRegion> paintDesktopLyricsSettings({
  required DesktopLyricsLayout layout,
  required SettingsPalette palette,
  required SettingsCanvas canvas,
  SettingsTextFit fit = identitySettingsTextFit,
  Rect? clipTo,
}) {
  final regions = <SettingsHitRegion>[];
  for (final op in layout.ops) {
    switch (op) {
      case final DesktopLyricsFillOp fill:
        canvas.fill(fill.left, fill.top, fill.width, fill.height, fill.color.resolve(palette));
      case final DesktopLyricsStrokeOp stroke:
        canvas.stroke(stroke.rect, stroke.color.resolve(palette));
      case final DesktopLyricsTextOp text:
        final maxWidth = text.fitMaxWidth;
        final value =
            maxWidth == null ? text.value : fit(text.value, text.size, maxWidth, text.weight);
        canvas.text(value, text.left, text.top, text.size, text.weight, text.tracking,
            text.color.resolve(palette));
      case final DesktopLyricsCenteredOp centered:
        final maxWidth = centered.fitMaxWidth;
        final value = maxWidth == null
            ? centered.value
            : fit(centered.value, centered.size, maxWidth, centered.weight);
        canvas.centered(
            value, centered.x, centered.cy, centered.size, centered.weight, centered.horizontal);
      case final DesktopLyricsHitOp hit:
        canvas.hit(hit.rect.left, hit.rect.top, hit.rect.width, hit.rect.height, hit.action, hit.label);
        regions.add(SettingsHitRegion(hit.rect, hit.action, hit.label));
    }
  }
  if (clipTo == null) {
    return regions;
  }
  return clipSettingsHits(regions, clipTo);
}

/// 命中裁剪的语义别名（Qt/src/NativeHudDesktopLyrics.cpp:99-104 的
/// HudScroll::clipHits(hits, firstHit, viewport)）。
List<SettingsHitRegion> desktopLyricsClipHits(
  List<SettingsHitRegion> hits,
  Rect viewport, {
  int first = 0,
}) =>
    clipSettingsHits(hits, viewport, first: first);

// ══════════════════════════════════════════════════════════════════════════════
// 15. 面板：视口、滚动轨道、滚动按钮（Qt/src/NativeHudDesktopLyrics.cpp:51-119）
// ══════════════════════════════════════════════════════════════════════════════

/// 视口与轨道的纯几何。
class DesktopLyricsPanelGeometry {
  const DesktopLyricsPanelGeometry._();

  /// Qt/src/NativeHudDesktopLyrics.cpp:35-36：
  /// (bounds.x + 40, bounds.y + 200, bounds.width - 80, 620)。
  static Rect viewportFor(Rect bounds) => Rect.fromLTWH(
        bounds.left + DesktopLyricsPanelMetrics.viewportInsetX,
        bounds.top + DesktopLyricsPanelMetrics.viewportTop,
        bounds.width - DesktopLyricsPanelMetrics.viewportInsetX * 2,
        DesktopLyricsPanelMetrics.viewportHeight,
      );

  /// Qt/src/NativeHudDesktopLyrics.cpp:106-109：
  /// railX = x + width - 24、railTop = y + 200 + 30、高度 = 视口高 - 60、宽 3。
  static Rect railTrackFor(Rect bounds) {
    final railLeft = bounds.left + bounds.width - DesktopLyricsPanelMetrics.railInset;
    final railTop =
        bounds.top + DesktopLyricsPanelMetrics.viewportTop + DesktopLyricsPanelMetrics.railTopInset;
    return Rect.fromLTWH(
      railLeft,
      railTop,
      DesktopLyricsPanelMetrics.railWidth,
      DesktopLyricsPanelMetrics.viewportHeight - DesktopLyricsPanelMetrics.railBottomInset,
    );
  }
}

/// 轨道与滑块（Qt/src/HudScroll.h:43-64 的 Rail）。
class DesktopLyricsRail {
  const DesktopLyricsRail({required this.visible, required this.track, required this.thumb});

  final bool visible;
  final Rect track;
  final Rect? thumb;

  @override
  String toString() => 'DesktopLyricsRail(visible: ' + visible.toString() + ')';
}

/// Qt/src/HudScroll.h:50-64 rail 的等价实现（含 minThumbHeight 默认 30）。
DesktopLyricsRail desktopLyricsRail({
  required Rect track,
  required double contentHeight,
  required double viewportHeight,
  required double offset,
  double minimumThumbHeight = DesktopLyricsPanelMetrics.railMinimumThumbHeight,
}) {
  final range = SettingsRowMetrics.maximumScroll(contentHeight, viewportHeight);
  if (range <= 0 || track.height <= 0) {
    return DesktopLyricsRail(visible: false, track: track, thumb: null);
  }
  final thumbHeight = desktopLyricsClampDouble(
    track.height * viewportHeight / contentHeight,
    math.min(minimumThumbHeight, track.height),
    track.height,
  );
  final thumbTop =
      track.top + desktopLyricsClampDouble(offset / range, 0, 1) * (track.height - thumbHeight);
  return DesktopLyricsRail(
    visible: true,
    track: track,
    thumb: Rect.fromLTWH(track.left, thumbTop, track.width, thumbHeight),
  );
}

/// 两个滚动按钮的矩形与动作（Qt/src/NativeHudDesktopLyrics.cpp:117-118）。
class DesktopLyricsScrollButtons {
  const DesktopLyricsScrollButtons({
    required this.up,
    required this.down,
    required this.upAction,
    required this.downAction,
    required this.upLabel,
    required this.downLabel,
  });

  final Rect up;
  final Rect down;
  final String upAction;
  final String downAction;
  final String upLabel;
  final String downLabel;
}

/// Qt/src/NativeHudDesktopLyrics.cpp:117-118：
/// up = (railX - 10, y + 200, 23, 25)、down = (railX - 10, y + 820 - 25, 23, 25)。
DesktopLyricsScrollButtons desktopLyricsScrollButtons(Rect bounds) {
  final railLeft = bounds.left + bounds.width - DesktopLyricsPanelMetrics.railInset;
  final buttonLeft = railLeft - DesktopLyricsPanelMetrics.scrollButtonOffsetX;
  return DesktopLyricsScrollButtons(
    up: Rect.fromLTWH(
      buttonLeft,
      bounds.top + DesktopLyricsPanelMetrics.viewportTop,
      DesktopLyricsPanelMetrics.scrollButtonWidth,
      DesktopLyricsPanelMetrics.scrollButtonHeight,
    ),
    down: Rect.fromLTWH(
      buttonLeft,
      bounds.top +
          DesktopLyricsPanelMetrics.viewportBottom -
          DesktopLyricsPanelMetrics.scrollButtonHeight,
      DesktopLyricsPanelMetrics.scrollButtonWidth,
      DesktopLyricsPanelMetrics.scrollButtonHeight,
    ),
    upAction: DesktopLyricsActions.scrollUp,
    downAction: DesktopLyricsActions.scrollDown,
    upLabel: DesktopLyricsPanelMetrics.scrollUpLabel,
    downLabel: DesktopLyricsPanelMetrics.scrollDownLabel,
  );
}

/// 面板绘制结果。
class DesktopLyricsPanelResult {
  const DesktopLyricsPanelResult({
    required this.viewport,
    required this.layout,
    required this.hits,
    required this.rail,
    required this.buttons,
    required this.buttonHits,
  });

  final Rect viewport;
  final DesktopLyricsLayout layout;

  /// 正文命中区，已按视口裁剪（Qt/src/NativeHudDesktopLyrics.cpp:99-104）。
  final List<SettingsHitRegion> hits;
  final DesktopLyricsRail rail;
  final DesktopLyricsScrollButtons buttons;

  /// 滚动按钮命中（Qt :117-118 在 clipHits 之后追加，因此不参与裁剪）。
  final List<SettingsHitRegion> buttonHits;

  @override
  String toString() => 'DesktopLyricsPanelResult(hits: ' +
      hits.length.toString() +
      ', buttons: ' +
      buttonHits.length.toString() +
      ')';
}

/// 绘制整个面板：正文 + 轨道 + 两个滚动按钮。
///
/// 逐条对应 Qt/src/NativeHudDesktopLyrics.cpp:51-119；按钮绘制走 NativeHud::button
/// （Qt/src/NativeHud.cpp:110-120：命中 + 底色 + 居中文本，inset = min(10, width/8)）。
DesktopLyricsPanelResult paintDesktopLyricsPanel({
  required Rect bounds,
  required double scroll,
  required bool enabled,
  required DesktopLyricsAppearance appearance,
  required int offsetMs,
  required bool dark,
  required SettingsPalette palette,
  required SettingsCanvas canvas,
  SettingsTextFit fit = identitySettingsTextFit,
  DesktopLyricsReflow? reflow,
}) {
  final viewport = DesktopLyricsPanelGeometry.viewportFor(bounds);
  final layout = layoutDesktopLyricsSettings(
    viewport: viewport,
    scroll: scroll,
    enabled: enabled,
    appearance: appearance,
    offsetMs: offsetMs,
    reflow: reflow,
  );
  final bodyHits = paintDesktopLyricsSettings(
    layout: layout,
    palette: palette,
    canvas: canvas,
    fit: fit,
    clipTo: viewport,
  );

  final track = DesktopLyricsPanelGeometry.railTrackFor(bounds);
  final rail = desktopLyricsRail(
    track: track,
    contentHeight: layout.contentHeight,
    viewportHeight: viewport.height,
    offset: scroll,
  );
  canvas.fill(
    track.left,
    track.top,
    track.width,
    track.height,
    dark ? const SettingsRgba(1, 1, 1, 0.1) : const SettingsRgba(0, 0, 0, 0.1),
  );
  final thumb = rail.thumb;
  if (thumb != null) {
    canvas.fill(
      thumb.left,
      thumb.top,
      thumb.width,
      thumb.height,
      dark ? const SettingsRgba(1, 1, 1, 0.45) : const SettingsRgba(0, 0, 0, 0.4),
    );
  }

  final buttons = desktopLyricsScrollButtons(bounds);
  final buttonHits = <SettingsHitRegion>[];

  void paintButton(Rect rect, String action, String label) {
    canvas.hit(rect.left, rect.top, rect.width, rect.height, action, label);
    final inset = math.min(10.0, rect.width / 8);
    canvas.fill(
      rect.left,
      rect.top,
      rect.width,
      rect.height,
      dark ? const SettingsRgba(0.55, 0.59, 0.46, 0.13) : const SettingsRgba(0.44, 0.49, 0.36, 0.1),
    );
    canvas.text(
      fit(label, DesktopLyricsPanelMetrics.scrollButtonFontSize, rect.width - inset * 2,
          SettingsFontWeight.regular),
      rect.left + inset,
      rect.top + (rect.height - DesktopLyricsPanelMetrics.scrollButtonFontSize) / 2 - 4,
      DesktopLyricsPanelMetrics.scrollButtonFontSize,
      SettingsFontWeight.regular,
      0,
      palette.ink,
    );
    buttonHits.add(SettingsHitRegion(rect, action, label));
  }

  paintButton(buttons.up, buttons.upAction, buttons.upLabel);
  paintButton(buttons.down, buttons.downAction, buttons.downLabel);

  return DesktopLyricsPanelResult(
    viewport: viewport,
    layout: layout,
    hits: bodyHits,
    rail: rail,
    buttons: buttons,
    buttonHits: buttonHits,
  );
}

// ══════════════════════════════════════════════════════════════════════════════
// 16. 已知边界（供审查逐条核对，不是待办清单）
// ══════════════════════════════════════════════════════════════════════════════
//
// 1. （相对 Qt 的有意收窄）QColor 文本形式只实现设置页会写出的 #RGB 与 #RRGGBB
//    （Qt/src/DesktopLyricsAppearance.cpp:23-29 的 QColor 还接受命名色、
//    #AARRGGBB、#RRRGGGBBB、rgb()/hsl() 等）。这些输入在本实现里走 fallback；
//    设置页与 resetAppearance 永远只产生六位小写形式，不影响页面自身闭环。
// 2. SettingsCanvas.centered 没有颜色参数（与 Qt Canvas 的 centered 一致），
//    所以 DesktopLyricsCenteredOp 不带颜色；段文字/加减号/偏移按钮文字经
//    Canvas.centered 落到空色分支，即 ink()（Qt/src/NativeHud.cpp:42）。
//    滚动按钮的文本颜色这里显式给 palette.ink——
//    Qt/src/NativeHud.cpp:118 的 text 调用不传颜色，而 NativeHud::text 在
//    color 为空时即取 ink()（Qt/src/NativeHud.cpp:42），故两者完全等价。
// 3. Qt 的 colorArray 用 QColor::redF()（float），这里用 red / 255（double），
//    存在 1 ulp 级差异，不影响像素。
// 4. 竖屏重排的纵向步长复用 Qt 已有数值：色块 30
//    （Qt/src/DesktopLyricsSettingsPage.cpp:158 的水平步长）、偏移按钮 44
//    （40 高 + 4 上缩，:280），没有引入新常量。
// 5. DesktopLyricsViewportTop / Bottom 在 Qt/src/NativeHud.h:126-127
//    （不在 NativeHudDesktopLyrics.cpp 里）。
// 6. 任务简报里「NativeHudDesktopLyrics.cpp:117-122 是模态标题/副标题/返回按钮命中」
//    与源码不符：:117-118 是两个滚动按钮，:121 起是动作分发；模态标题/副标题/返回
//    按钮实际在 Qt/src/NativeHudModal.cpp:29、:55、:199-200。
// 7. 开关（desktop-lyrics）的 normalizeDesktopLyricsValue 采用写语义：
//    无条件写成 on/off（Qt/src/NativeHudDesktopLyrics.cpp:181-183），
//    它不是外观键（Qt/src/DesktopLyricsAppearance.cpp:91-101）。
// 8. 各命中区的 label 逐字取自 Qt 调用点（段控与步进器用行内 label，
//    例如「正文字号」；调色板用颜色中文名；偏移按钮用按钮文字），
//    不等于 titleZh（titleZh 是「字号」）。

